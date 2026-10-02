import CoreGraphics
import Foundation

/// analyze_take: what to cut, from what was recorded and what the files show.
@MainActor
enum AgentAnalysisTools {
    /// How long analyze_take waits for a scan before saying it's still running.
    static let defaultWait: TimeInterval = 40

    static func analyzeTake(_ arguments: AgentArguments, _ context: AgentToolContext) async throws -> JSONValue {
        try context.ensureNotRecording()
        let summary = try context.resolveTake(arguments)
        let take = try context.load(summary)
        let project = take.project
        let wait = try arguments.double("wait_seconds", in: 0...600) ?? defaultWait
        let focus = project.inputs.appFocus
        let app = try arguments.string("app")
        if let app, !focus.isEmpty, !focus.contains(where: { $0.isApp(app) }) {
            let apps = AppFocusTimeline.quotedNames(focus, duration: project.metadata.duration)
            throw AgentToolError("\"\(app)\" wasn't in front during this take. Apps in this take: \(apps).")
        }

        let key = context.scanner.start(project)
        let state = try await context.scanner.wait(key, timeout: wait, progress: context.progress)
        switch state {
        case let .running(progress):
            let percent = Int((progress * 100).rounded())
            let value: JSONValue = [
                "take_id": .string(summary.id.uuidString),
                "status": "running",
                "progress": .number((progress * 100).rounded() / 100)
            ]
            return MCPToolResult.structured(
                value,
                summary: "Still reading \(summary.displayName) (\(percent)%). Call analyze_take again shortly; the work isn't lost."
            )
        case let .failed(message):
            throw AgentToolError("Couldn't read \(summary.displayName)'s recording: \(message)")
        case let .done(scan):
            let input = TakeAnalysisInput(
                duration: project.metadata.duration,
                frameSize: CGSize(width: project.metadata.width, height: project.metadata.height),
                clicks: project.clickEvents,
                keystrokes: project.inputs.keystrokes,
                cursor: project.cursorEvents,
                screen: scan.screen,
                speech: scan.speech,
                focus: focus.isEmpty ? nil : focus,
                focusApp: app
            )
            let analysis = TakeAnalyzer().analyze(input)
            var value = analysis.json.objectValue ?? [:]
            value["take_id"] = .string(summary.id.uuidString)
            value["status"] = "done"
            value["current_output_duration"] = AgentTime.json(take.timeline.outputDuration)
            return MCPToolResult.structured(.object(value), summary: analysis.summary)
        }
    }
}
