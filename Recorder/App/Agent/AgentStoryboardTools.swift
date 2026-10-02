import Foundation

/// render_storyboard: an agent's storyboard (StoryboardRecipe) as one undo step, with a
/// contact sheet of its shots.
@MainActor
enum AgentStoryboardTools {
    static func renderStoryboard(_ arguments: AgentArguments, _ context: AgentToolContext) async throws -> JSONValue {
        try context.ensureNotRecording()
        let summary = try context.resolveTake(arguments)
        let project = try context.load(summary).project
        let storyboard = try Storyboard(arguments, duration: project.metadata.duration)
        // Wrong names fail before anything changes.
        try AgentAnalysisTools.checkApp(storyboard.app, in: project)
        if let look = storyboard.look {
            _ = try AgentEdits.look(named: look, in: StyleLibraryStore.load().allPresets)
        }
        let preview = try arguments.bool("preview") ?? true

        // The shots are chosen, so the recording needn't be read: clicks, the apps in front
        // and what covered them are enough.
        let analysis = AgentAnalysisTools.analyze(project, scan: TakeMediaScan(frameTimes: [], screen: nil, speech: nil), app: storyboard.app)
        context.progress.report(0.1, "Editing")
        var report = StoryboardReport()
        let applied = try AgentEditTools.applyEdit("Storyboard", arguments, context) { snapshot, take in
            report = try StoryboardRecipe(storyboard: storyboard).apply(to: &snapshot, take: take, analysis: analysis)
            return report.changes
        }

        var images: [Data] = []
        if preview, !report.shots.isEmpty {
            let timeline = applied.snapshot.editSettings.resolvedTimeline(sourceDuration: applied.project.metadata.duration)
            let moments = report.shots.prefix(FrameSampling.maximumSheetTiles).map { shot -> AgentFrameMoment in
                // Where its text is up, or its middle.
                let output = shot.textOutput.map { ($0.start + $0.end) / 2 } ?? (shot.output.start + shot.output.end) / 2
                return AgentFrameMoment(source: timeline.sourceTime(forOutput: output), output: output)
            }
            let progress = context.progress
            let rendering = MCPProgress { value, message in progress.report(0.2 + value * 0.8, message) }
            images = try await AgentTakeTools.renderFrames(
                applied.project,
                snapshot: applied.snapshot,
                moments: Array(moments),
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
            value["preview"] = .string("A contact sheet with one frame per shot (its text, or its middle), as it will export, labelled in output time.")
        }
        let length = LaunchDemoRecipe.seconds(report.outputDuration)
        let hook = report.hookOK ? "The hook lands in the first 2 s." : "The hook is weak (see warnings)."
        let issues = report.warnings.isEmpty ? "No warnings." : "\(report.warnings.count) warning\(report.warnings.count == 1 ? "" : "s")."
        return MCPToolResult.structured(
            .object(value),
            summary: "Rendered \(report.shots.count) shots into a \(length) video. \(hook) \(issues) Score and fix it with critique_video.",
            images: images.map { (data: $0, mimeType: "image/jpeg") }
        )
    }
}
