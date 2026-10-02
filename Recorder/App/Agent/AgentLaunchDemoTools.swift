import Foundation

/// make_launch_demo: the whole launch-demo pass (LaunchDemoRecipe) as one undo step, with
/// a rendered contact sheet of the result.
@MainActor
enum AgentLaunchDemoTools {
    /// Frames in the preview contact sheet.
    static let previewFrames = 8

    static func makeLaunchDemo(_ arguments: AgentArguments, _ context: AgentToolContext) async throws -> JSONValue {
        try context.ensureNotRecording()
        let options = try LaunchDemoOptions(arguments)
        let preview = try arguments.bool("preview") ?? true
        let wait = try arguments.double("wait_seconds", in: 0...600) ?? AgentAnalysisTools.defaultWait
        let summary = try context.resolveTake(arguments)
        let project = try context.load(summary).project
        // Wrong names fail now, not after reading the recording.
        try AgentAnalysisTools.checkApp(options.app, in: project)
        if let look = options.look {
            _ = try AgentEdits.look(named: look, in: StyleLibraryStore.load().allPresets)
        }

        // Reading the recording is most of the work (and cached for analyze_take).
        let progress = context.progress
        let reading = MCPProgress { value, message in progress.report(value * 0.7, message) }
        let key = context.scanner.start(project)
        let scan: TakeMediaScan
        switch try await context.scanner.wait(key, timeout: wait, progress: reading) {
        case let .running(fraction):
            return AgentAnalysisTools.stillReading(summary, progress: fraction, tool: "make_launch_demo")
        case let .failed(message):
            throw AgentToolError("Couldn't read \(summary.displayName)'s recording: \(message)")
        case let .done(result):
            scan = result
        }
        try context.ensureNotRecording()
        let analysis = AgentAnalysisTools.analyze(project, scan: scan, app: options.app)

        progress.report(0.72, "Editing")
        var report = LaunchDemoReport()
        let applied = try AgentEditTools.applyEdit("Launch Demo", arguments, context) { snapshot, take in
            report = try LaunchDemoRecipe(options: options).apply(to: &snapshot, take: take, analysis: analysis)
            return report.changes
        }

        var images: [Data] = []
        if preview {
            let timeline = applied.snapshot.editSettings.resolvedTimeline(sourceDuration: applied.project.metadata.duration)
            let times = FrameSampling.evenlySpaced(count: previewFrames, in: TimeSpan(start: 0, end: timeline.outputDuration))
            let moments = times.map { AgentFrameMoment(source: timeline.sourceTime(forOutput: $0), output: $0) }
            let rendering = MCPProgress { value, message in progress.report(0.75 + value * 0.25, message) }
            images = try await AgentTakeTools.renderFrames(
                applied.project,
                snapshot: applied.snapshot,
                moments: moments,
                rendered: true,
                asSheet: true,
                grid: false,
                labelTimeBase: .output,
                progress: rendering
            )
        }

        var value = report.json.objectValue ?? [:]
        value["take_id"] = .string(summary.id.uuidString)
        value["live_in_editor"] = .bool(applied.live)
        if !images.isEmpty {
            value["preview"] = .string("A contact sheet of \(previewFrames) frames of the finished video, as it will export, labelled in output time.")
        }
        let undo = applied.live
            ? "It's live in Trace's editor; ⌘Z there or the undo tool reverts it."
            : "Saved; the undo tool reverts it."
        let length = LaunchDemoRecipe.seconds(report.outputDuration)
        return MCPToolResult.structured(
            .object(value),
            summary: "Made \(summary.displayName) into a \(length) launch demo. \(undo) Check it with view_frames (rendered true), then export_video.",
            images: images.map { (data: $0, mimeType: "image/jpeg") }
        )
    }
}
