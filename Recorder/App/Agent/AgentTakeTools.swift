import Foundation

/// The reading tools: list_takes, get_take, view_frames and open_take.
@MainActor
enum AgentTakeTools {
    static func listTakes(_ arguments: AgentArguments, _ context: AgentToolContext) throws -> JSONValue {
        let requested = try arguments.int("limit") ?? 50
        let limit = min(max(requested, 1), 200)
        let query = try arguments.string("query")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let all = ProjectStore.listProjects()
        let matching = query.isEmpty ? all : all.filter { $0.matches(query) }
        let entries: [JSONValue] = matching.prefix(limit).map { summary in
            let editor = context.appState.session.editor(for: summary.id)
            let metadata = try? ProjectStore.loadMetadata(from: summary.bundleURL)
            let settings = editor?.editSettings ?? (try? ProjectStore.loadEditSettings(from: summary.bundleURL))
            return TakeDescription.listEntry(summary: summary, metadata: metadata, editSettings: settings, isOpen: editor != nil)
        }
        let result: JSONValue = ["takes": .array(entries), "total": .number(Double(matching.count))]
        let summary: String
        if matching.isEmpty {
            summary = query.isEmpty ? "The library is empty." : "No takes match \"\(query)\"."
        } else {
            summary = "\(matching.count) take\(matching.count == 1 ? "" : "s"), newest first."
        }
        return MCPToolResult.structured(result, summary: summary)
    }

    static func getTake(_ arguments: AgentArguments, _ context: AgentToolContext) throws -> JSONValue {
        let summary = try context.resolveTake(arguments)
        let take = try context.load(summary)
        let detail = TakeDescription.detail(
            project: take.project,
            keyframes: take.keyframes,
            editSettings: take.editSettings,
            isOpen: take.editor != nil
        )
        let length = Timecode.precise(take.project.metadata.duration)
        let edited = Timecode.precise(take.timeline.outputDuration)
        return MCPToolResult.structured(detail, summary: "\(summary.displayName): \(length) recorded, \(edited) after the edit.")
    }

    static func openTake(_ arguments: AgentArguments, _ context: AgentToolContext) throws -> JSONValue {
        try context.ensureNotRecording()
        let summary = try context.resolveTake(arguments)
        context.appState.openProject(summary)
        let result: JSONValue = ["take_id": .string(summary.id.uuidString), "opened": true]
        return MCPToolResult.structured(result, summary: "Opened \(summary.displayName) in Trace's editor.")
    }

    static func viewFrames(_ arguments: AgentArguments, _ context: AgentToolContext) async throws -> JSONValue {
        try context.ensureNotRecording()
        let summary = try context.resolveTake(arguments)
        let take = try context.load(summary)
        let rendered = try arguments.bool("rendered") ?? false
        let grid = try arguments.bool("grid") ?? false
        let layout = try arguments.string("layout") ?? "sheet"
        guard layout == "sheet" || layout == "frames" else {
            throw AgentToolError("layout must be \"sheet\" or \"frames\".")
        }
        let asSheet = layout == "sheet"
        let timeBase = try AgentTimeBase.read(arguments, default: rendered ? .output : .source)
        let moments = try frameMoments(arguments, take: take, timeBase: timeBase, asSheet: asSheet)

        // The renderer draws the recorded cursor with the system's own images.
        SystemCursorImages.shared.load()
        context.progress.report(0.02, "Reading \(moments.count) frame\(moments.count == 1 ? "" : "s")")
        let project = take.project
        let source = CGSize(width: project.metadata.width, height: project.metadata.height)
        let request = AgentFrameRenderer.Request(
            videoURL: project.videoURL,
            cameraURL: take.editSettings.camera.isVisible && project.hasCameraTrack ? project.cameraURL : nil,
            moments: moments,
            rendered: rendered,
            keyframes: take.keyframes,
            renderSettings: CompositionRenderSettings(project: project, editSettings: take.editSettings),
            canvasSize: take.editSettings.canvas.pixelSize(source: source),
            sourceSize: source,
            asSheet: asSheet,
            grid: grid && !rendered,
            labelTimeBase: timeBase
        )
        let images = try await AgentFrameRenderer.render(request, progress: context.progress)

        let frames: [JSONValue] = moments.enumerated().map { index, moment in
            var frame: [String: JSONValue] = [
                "index": .number(Double(index + 1)),
                "source_time": AgentTime.json(moment.source)
            ]
            if let output = moment.output {
                frame["output_time"] = AgentTime.json(output)
            } else {
                frame["cut"] = true
            }
            return .object(frame)
        }
        var result: [String: JSONValue] = [
            "take_id": .string(summary.id.uuidString),
            "rendered": .bool(rendered),
            "layout": .string(layout),
            "frames": .array(frames)
        ]
        if grid && !rendered {
            result["grid"] = "Lines every 0.1, labelled along the top (x) and left (y); origin top-left."
        }
        let what = rendered ? "as exported" : "raw recording"
        let label = asSheet ? "Contact sheet of \(moments.count) frames (\(what)), numbered in order." : "\(moments.count) frame(s) (\(what))."
        return MCPToolResult.structured(
            .object(result),
            summary: label,
            images: images.map { (data: $0, mimeType: "image/jpeg") }
        )
    }

    /// The moments to show, each on both clocks (`output` is nil where the edit cut it).
    private static func frameMoments(
        _ arguments: AgentArguments,
        take: AgentTakeState,
        timeBase: AgentTimeBase,
        asSheet: Bool
    ) throws -> [AgentFrameMoment] {
        let timeline = take.timeline
        let clockLength = timeBase == .output ? timeline.outputDuration : take.project.metadata.duration
        let limit = asSheet ? FrameSampling.maximumSheetTiles : FrameSampling.maximumFrames

        var times: [TimeInterval]
        if let list = try arguments.array("times") {
            times = try list.enumerated().map { index, value in
                guard let time = AgentTime.parse(value) else {
                    throw AgentToolError("times[\(index)] isn't a time (use seconds or \"m:ss.s\").")
                }
                return time
            }
            guard !times.isEmpty else {
                throw AgentToolError("times is empty.")
            }
            guard times.count <= limit else {
                throw AgentToolError("At most \(limit) frames for layout \"\(asSheet ? "sheet" : "frames")\".")
            }
        } else {
            let fallback = asSheet ? FrameSampling.defaultSheetCount : FrameSampling.defaultFrameCount
            let count = try arguments.int("count") ?? fallback
            guard (1...limit).contains(count) else {
                throw AgentToolError("count must be 1–\(limit) for layout \"\(asSheet ? "sheet" : "frames")\".")
            }
            var span = TimeSpan(start: 0, end: clockLength)
            if let range = try arguments.object("range") {
                let start = try range.time("start") ?? 0
                let end = try range.time("end") ?? clockLength
                guard end > start else {
                    throw AgentToolError("range.end must come after range.start.")
                }
                span = TimeSpan(start: max(0, start), end: min(clockLength, end))
            }
            times = FrameSampling.evenlySpaced(count: count, in: span)
        }

        return try times.map { time in
            guard time >= -0.001, time <= clockLength + 0.001 else {
                let clock = timeBase == .output ? "edited video" : "recording"
                throw AgentToolError("\(AgentArguments.format(time)) s is outside the \(clock) (0–\(AgentArguments.format(clockLength)) s).")
            }
            let clamped = min(max(time, 0), max(clockLength - 0.001, 0))
            switch timeBase {
            case .source:
                return AgentFrameMoment(source: clamped, output: timeline.outputTime(forSource: clamped))
            case .output:
                return AgentFrameMoment(source: timeline.sourceTime(forOutput: clamped), output: clamped)
            }
        }
    }
}
