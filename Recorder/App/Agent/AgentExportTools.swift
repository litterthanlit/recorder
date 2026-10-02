import Foundation

/// Exports AI agents started. They run one at a time, in the order they were asked for,
/// in the background: an agent waits on one for a while, then polls it by id.
@MainActor
final class AgentExportJobs {
    @MainActor
    final class Job {
        enum State: Equatable {
            case queued
            case running
            case done(URL)
            case failed(String)
            case cancelled

            var name: String {
                switch self {
                case .queued: return "queued"
                case .running: return "running"
                case .done: return "done"
                case .failed: return "failed"
                case .cancelled: return "cancelled"
                }
            }
        }

        let id: String
        let takeID: UUID
        let takeName: String
        let options: ExportOptions
        let destination: URL
        /// Length of the edited video, seconds.
        let outputDuration: TimeInterval
        let started = Date()
        fileprivate(set) var state: State = .queued
        /// 0…1 while running.
        fileprivate(set) var progress: Double = 0
        fileprivate(set) var finished: Date?
        fileprivate(set) var cancelRequested = false
        fileprivate var task: Task<Void, Never>?

        fileprivate init(id: String, takeID: UUID, takeName: String, options: ExportOptions, destination: URL, outputDuration: TimeInterval) {
            self.id = id
            self.takeID = takeID
            self.takeName = takeName
            self.options = options
            self.destination = destination
            self.outputDuration = outputDuration
        }

        var isFinished: Bool {
            finished != nil
        }

        fileprivate func finish(_ state: State) {
            guard finished == nil else { return }
            self.state = state
            finished = Date()
        }
    }

    /// Newest last. Finished ones are forgotten once there are more than `remembered`.
    private var jobs: [Job] = []
    private var lastTask: Task<Void, Never>?
    private static let remembered = 20

    func job(id: String) -> Job? {
        jobs.first { $0.id == id }
    }

    var latest: Job? {
        jobs.last
    }

    /// Whether an unfinished export is writing to `url`, so a new one picks another name.
    func isWriting(to url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return jobs.contains { !$0.isFinished && $0.destination.standardizedFileURL.path == path }
    }

    /// Queues an export of `project` (as given: the caller picks the edit to export).
    func start(
        project: RecorderProject,
        takeName: String,
        options: ExportOptions,
        destination: URL,
        outputDuration: TimeInterval,
        onFinish: @escaping @MainActor (Job) -> Void
    ) -> Job {
        let id = "exp_" + UUID().uuidString.prefix(8).lowercased()
        let job = Job(
            id: id,
            takeID: project.metadata.id,
            takeName: takeName,
            options: options,
            destination: destination,
            outputDuration: outputDuration
        )
        let previous = lastTask
        job.task = Task {
            await previous?.value
            // Cancelled while it waited its turn.
            guard !job.isFinished else { return }
            job.state = .running
            do {
                let url = try await ExportService.export(project, options: options, to: destination) { value in
                    guard job.state == .running else { return }
                    job.progress = min(max(value, job.progress), 1)
                }
                job.finish(.done(url))
            } catch is CancellationError {
                job.finish(.cancelled)
            } catch {
                Log.agent.error("Agent export failed: \(error.localizedDescription, privacy: .public)")
                job.finish(.failed(error.localizedDescription))
            }
            onFinish(job)
        }
        lastTask = job.task
        jobs.append(job)
        forgetOldJobs()
        return job
    }

    func cancel(_ job: Job) {
        guard !job.isFinished else { return }
        job.cancelRequested = true
        if job.state == .queued {
            job.finish(.cancelled)
        }
        job.task?.cancel()
    }

    /// Waits up to `timeout` seconds for `job` to finish, reporting its progress.
    /// Throws `CancellationError` if the agent stops waiting (the export goes on).
    func wait(for job: Job, timeout: TimeInterval, progress: MCPProgress) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !job.isFinished, ProcessInfo.processInfo.systemUptime < deadline {
            if job.state == .running {
                // Never 1: that's for the result.
                progress.report(min(job.progress, 0.99), "Exporting \(job.takeName): \(Int((job.progress * 100).rounded()))%")
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private func forgetOldJobs() {
        while jobs.count > Self.remembered, let index = jobs.firstIndex(where: { $0.isFinished }) {
            jobs.remove(at: index)
        }
    }
}

/// The export tools: export_video and export_status.
@MainActor
enum AgentExportTools {
    /// How long export_video waits before handing back an id to poll.
    static let defaultWait: TimeInterval = 45
    static let defaultStatusWait: TimeInterval = 30
    static let maximumWait: TimeInterval = 600

    static func exportVideo(_ arguments: AgentArguments, _ context: AgentToolContext) async throws -> JSONValue {
        try context.ensureNotRecording()
        let summary = try context.resolveTake(arguments)
        let take = try context.load(summary)
        // The edit as it is now, including changes the editor hasn't saved yet.
        var project = take.project
        project.keyframes = take.keyframes
        project.editSettings = take.editSettings

        var preferences = ExportPreferences.load()
        var options = preferences.options
        if let format = try arguments.choice("format", ExportFormat.self) {
            options.format = format
        }
        if let quality = try arguments.choice("quality", ExportQuality.self) {
            options.quality = quality
        }
        if let fps = try arguments.int("fps") {
            guard ExportOptions.frameRateChoices.contains(fps) else {
                throw AgentToolError("fps must be 24, 30 or 60 (leave it out for the recording's own rate).")
            }
            options.frameRate = fps
        }
        let duration = take.timeline.outputDuration
        guard ExportOptions.allows(options.format, duration: duration) else {
            let limit = AgentArguments.format(ExportOptions.gifMaximumDuration)
            throw AgentToolError(
                "A GIF can be at most \(limit) s and this edit runs \(Timecode.precise(duration)). Cut it shorter, or export mp4."
            )
        }
        preferences.options = options
        let wait = try arguments.double("wait_seconds", in: 0...maximumWait) ?? defaultWait
        let library = context.appState.library

        if let list = try arguments.array("aspects") {
            let aspects = try AgentAspect.parseList(list, key: "aspects")
            let reframe = try arguments.bool("reframe") ?? true
            let take = AgentEditTake(project: project, looks: [])
            let edit = EditorSnapshot(keyframes: project.keyframes, editSettings: project.editSettings)
            var jobs: [AgentExportJobs.Job] = []
            for aspect in aspects {
                let shaped = edit.variant(for: aspect, reframe: reframe, take: take)
                var variant = project
                variant.keyframes = shaped.keyframes
                variant.editSettings = shaped.editSettings
                let destination = try self.destination(
                    arguments,
                    project: variant,
                    preferences: preferences,
                    jobs: context.exports,
                    suffix: " " + AgentAspect.name(aspect).replacingOccurrences(of: ":", with: "x")
                )
                jobs.append(context.exports.start(
                    project: variant,
                    takeName: "\(summary.displayName) (\(AgentAspect.name(aspect)))",
                    options: options,
                    destination: destination,
                    outputDuration: duration
                ) { _ in
                    library.refresh()
                })
            }
            do {
                // They run one after another, all within the one wait.
                let deadline = ProcessInfo.processInfo.systemUptime + wait
                for job in jobs {
                    let left = max(deadline - ProcessInfo.processInfo.systemUptime, 0)
                    try await context.exports.wait(for: job, timeout: left, progress: context.progress)
                }
            } catch is CancellationError {
                jobs.forEach { context.exports.cancel($0) }
                throw CancellationError()
            }
            return statuses(jobs)
        }

        let destination = try self.destination(arguments, project: project, preferences: preferences, jobs: context.exports)
        let job = context.exports.start(
            project: project,
            takeName: summary.displayName,
            options: options,
            destination: destination,
            outputDuration: duration
        ) { _ in
            library.refresh()
        }
        do {
            try await context.exports.wait(for: job, timeout: wait, progress: context.progress)
        } catch is CancellationError {
            // The agent gave up before it learned the export's id: stop it too.
            context.exports.cancel(job)
            throw CancellationError()
        }
        return status(job)
    }

    static func exportStatus(_ arguments: AgentArguments, _ context: AgentToolContext) async throws -> JSONValue {
        let job: AgentExportJobs.Job
        if let id = try arguments.string("export_id")?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            guard let found = context.exports.job(id: id) else {
                throw AgentToolError("No export has the export_id \"\(id)\". Trace forgets exports when it quits; start a new one with export_video.")
            }
            job = found
        } else if let latest = context.exports.latest {
            job = latest
        } else {
            throw AgentToolError("No exports since Trace started. Start one with export_video.")
        }

        if try arguments.bool("cancel") == true {
            context.exports.cancel(job)
            // Stopping the writer takes a moment.
            try await context.exports.wait(for: job, timeout: 5, progress: .ignored)
            return status(job)
        }
        let wait = try arguments.double("wait_seconds", in: 0...maximumWait) ?? defaultStatusWait
        try await context.exports.wait(for: job, timeout: wait, progress: context.progress)
        return status(job)
    }

    /// Where the file goes: `folder` (or the export folder from Settings), named
    /// `file_name` (or from the naming template), never replacing a file.
    static func destination(
        _ arguments: AgentArguments,
        project: RecorderProject,
        preferences: ExportPreferences,
        jobs: AgentExportJobs,
        suffix: String = ""
    ) throws -> URL {
        var folder = preferences.folderURL
        if let path = try arguments.string("folder") {
            let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else {
                throw AgentToolError("folder must be a full path, like ~/Desktop or /Users/you/Movies (got \"\(path)\").")
            }
            folder = URL(fileURLWithPath: expanded, isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                throw AgentToolError("\(folder.path) is a file, not a folder.")
            }
        }

        var template = preferences.fileNameTemplate
        if let requested = try arguments.string("file_name") {
            var base = requested.trimmingCharacters(in: .whitespacesAndNewlines)
            // The format decides the extension.
            if ["mp4", "mov", "m4v", "gif"].contains((base as NSString).pathExtension.lowercased()) {
                base = (base as NSString).deletingPathExtension
            }
            guard !base.isEmpty else {
                throw AgentToolError("file_name is empty.")
            }
            template = base
        }
        let fileName = ExportNaming.fileName(
            template: template + suffix,
            name: project.metadata.name ?? ProjectSummary.title(for: project.metadata),
            date: project.metadata.createdAt,
            fileExtension: preferences.options.format.fileExtension
        )
        return ExportNaming.uniqueURL(in: folder, fileName: fileName) { url in
            FileManager.default.fileExists(atPath: url.path) || jobs.isWriting(to: url)
        }
    }

    static func status(_ job: AgentExportJobs.Job) -> JSONValue {
        let parts = statusParts(job)
        return MCPToolResult.structured(parts.value, summary: parts.summary, files: parts.files, isError: parts.isError)
    }

    /// Several exports, one after another (one per shape).
    static func statuses(_ jobs: [AgentExportJobs.Job]) -> JSONValue {
        let parts = jobs.map { statusParts($0) }
        let value: JSONValue = ["exports": .array(parts.map { $0.value })]
        return MCPToolResult.structured(
            value,
            summary: parts.map { $0.summary }.joined(separator: " "),
            files: parts.flatMap { $0.files },
            isError: parts.contains { $0.isError }
        )
    }

    private static func statusParts(_ job: AgentExportJobs.Job) -> (value: JSONValue, summary: String, files: [URL], isError: Bool) {
        var value: [String: JSONValue] = [
            "export_id": .string(job.id),
            "take_id": .string(job.takeID.uuidString),
            "status": .string(job.cancelRequested && !job.isFinished ? "cancelling" : job.state.name),
            "format": .string(job.options.format.rawValue),
            "progress": .number((job.progress * 100).rounded() / 100),
            "path": .string(job.destination.path),
            "output_duration": AgentTime.json(job.outputDuration)
        ]
        var files: [URL] = []
        var isError = false
        let summary: String
        switch job.state {
        case .queued:
            summary = "Export \(job.id) is waiting for another export to finish. Check on it with export_status."
        case .running:
            let percent = Int((job.progress * 100).rounded())
            summary = job.cancelRequested
                ? "Stopping export \(job.id)."
                : "Exporting \(job.takeName): \(percent)%. Check on it with export_status (export_id \(job.id))."
        case let .done(url):
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let bytes = (attributes?[.size] as? NSNumber)?.int64Value
            if let bytes {
                value["bytes"] = .number(Double(bytes))
            }
            if let finished = job.finished {
                value["seconds"] = .number((finished.timeIntervalSince(job.started) * 10).rounded() / 10)
            }
            value["path"] = .string(url.path)
            files = [url]
            let size = bytes.map { " (" + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) + ")" } ?? ""
            summary = "Exported \(job.takeName) to \(url.path)\(size)."
        case let .failed(message):
            value["error"] = .string(message)
            isError = true
            summary = "The export failed: \(message)"
        case .cancelled:
            summary = "Export \(job.id) was cancelled; no file was written."
        }
        return (.object(value), summary, files, isError)
    }
}
