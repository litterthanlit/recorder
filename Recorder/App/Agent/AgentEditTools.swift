import Foundation

/// Undo for agents' edits to takes that aren't open, until the take is opened (then the
/// editor takes the history over, so ⌘Z there undoes them too).
@MainActor
final class AgentEditJournal {
    struct Undone {
        let snapshot: EditorSnapshot
        let actionName: String
    }

    private var histories: [UUID: EditHistory<EditorSnapshot>] = [:]

    func record(_ before: EditorSnapshot, actionName: String, for take: UUID) {
        var history = histories[take] ?? EditHistory<EditorSnapshot>()
        history.record(before, actionName: actionName, now: ProcessInfo.processInfo.systemUptime)
        histories[take] = history
    }

    func undo(for take: UUID, from current: EditorSnapshot) -> Undone? {
        guard var history = histories[take], let name = history.undoActionName,
              let previous = history.undo(from: current)
        else { return nil }
        histories[take] = history
        return Undone(snapshot: previous, actionName: name)
    }

    /// The history for a take that's opening in the editor (forgotten here).
    func handOff(_ take: UUID) -> EditHistory<EditorSnapshot>? {
        histories.removeValue(forKey: take)
    }
}

/// The editing tools: edit_timeline, edit_zooms, edit_text, edit_blur, set_style and undo.
/// An open take is edited live in the editor (one undo step there); a closed one on disk.
@MainActor
enum AgentEditTools {
    static func editTimeline(_ arguments: AgentArguments, _ context: AgentToolContext) throws -> JSONValue {
        let timeBase = try AgentTimeBase.read(arguments)
        let operations = try requiredOperations(arguments)
        return try apply("Timeline", arguments, context) { snapshot, take in
            try AgentEdits.editTimeline(&snapshot, operations: operations, take: take, timeBase: timeBase)
        }
    }

    static func editZooms(_ arguments: AgentArguments, _ context: AgentToolContext) throws -> JSONValue {
        let timeBase = try AgentTimeBase.read(arguments)
        let operations = try requiredOperations(arguments)
        return try apply("Zooms", arguments, context) { snapshot, take in
            try AgentEdits.editZooms(&snapshot, operations: operations, take: take, timeBase: timeBase)
        }
    }

    static func editText(_ arguments: AgentArguments, _ context: AgentToolContext) throws -> JSONValue {
        let timeBase = try AgentTimeBase.read(arguments)
        let operations = try requiredOperations(arguments)
        return try apply("Text", arguments, context) { snapshot, take in
            try AgentEdits.editText(&snapshot, operations: operations, take: take, timeBase: timeBase)
        }
    }

    static func editBlur(_ arguments: AgentArguments, _ context: AgentToolContext) throws -> JSONValue {
        let timeBase = try AgentTimeBase.read(arguments)
        let operations = try requiredOperations(arguments)
        return try apply("Blur", arguments, context) { snapshot, take in
            try AgentEdits.editBlur(&snapshot, operations: operations, take: take, timeBase: timeBase)
        }
    }

    static func editCameraMoves(_ arguments: AgentArguments, _ context: AgentToolContext) throws -> JSONValue {
        let timeBase = try AgentTimeBase.read(arguments)
        let operations = try requiredOperations(arguments)
        return try apply("3D Moves", arguments, context) { snapshot, take in
            try AgentEdits.editCameraMoves(&snapshot, operations: operations, take: take, timeBase: timeBase)
        }
    }

    static func setCrop(_ arguments: AgentArguments, _ context: AgentToolContext) throws -> JSONValue {
        try apply("Crop", arguments, context) { snapshot, take in
            try AgentEdits.setCrop(&snapshot, arguments: arguments, take: take)
        }
    }

    static func setStyle(_ arguments: AgentArguments, _ context: AgentToolContext) throws -> JSONValue {
        try apply("Style", arguments, context) { snapshot, take in
            try AgentEdits.setStyle(&snapshot, arguments: arguments, take: take)
        }
    }

    static func undo(_ arguments: AgentArguments, _ context: AgentToolContext) throws -> JSONValue {
        let summary = try context.resolveTake(arguments)
        let force = try arguments.bool("force") ?? false
        if let editor = context.appState.session.editor(for: summary.id) {
            if let name = editor.undoAgentEdit(force: force) {
                return result(summary, notes: ["Undid \"\(name)\"."], project: editor.project, snapshot: editor.currentSnapshot, live: true)
            }
            if let last = editor.undoActionName {
                throw AgentToolError("The last change in Trace's editor is the person's own (\"\(last)\"), not an agent's. Pass force: true to undo it anyway.")
            }
            throw AgentToolError("There's nothing to undo in this take.")
        }
        var project = try context.loadProject(summary)
        let current = EditorSnapshot(keyframes: project.keyframes, editSettings: project.editSettings)
        guard let undone = context.journal.undo(for: summary.id, from: current) else {
            throw AgentToolError("No agent edits to undo for this take since Trace started.")
        }
        project.keyframes = undone.snapshot.keyframes
        project.editSettings = undone.snapshot.editSettings
        try save(project)
        return result(summary, notes: ["Undid \"\(undone.actionName)\"."], project: project, snapshot: undone.snapshot, live: false)
    }

    /// An edit as applied: the take and its state afterwards.
    struct Applied {
        let summary: ProjectSummary
        let notes: [String]
        let project: RecorderProject
        let snapshot: EditorSnapshot
        /// Made in the open editor rather than on disk.
        let live: Bool
    }

    /// Applies `edit` to a take: live in the open editor, or on disk (remembered so the
    /// undo tool can take it back).
    static func apply(
        _ title: String,
        _ arguments: AgentArguments,
        _ context: AgentToolContext,
        edit: (inout EditorSnapshot, AgentEditTake) throws -> [String]
    ) throws -> JSONValue {
        let applied = try applyEdit(title, arguments, context, edit: edit)
        return result(applied.summary, notes: applied.notes, project: applied.project, snapshot: applied.snapshot, live: applied.live)
    }

    /// `apply`, returning the take as it is afterwards.
    static func applyEdit(
        _ title: String,
        _ arguments: AgentArguments,
        _ context: AgentToolContext,
        edit: (inout EditorSnapshot, AgentEditTake) throws -> [String]
    ) throws -> Applied {
        let summary = try context.resolveTake(arguments)
        let looks = StyleLibraryStore.load().allPresets
        let actionName = AgentEdits.actionPrefix + title

        if let editor = context.appState.session.editor(for: summary.id) {
            let take = AgentEditTake(project: editor.project, looks: looks)
            var notes: [String] = []
            try editor.applyExternalEdit(actionName) { snapshot in
                notes = try edit(&snapshot, take)
            }
            return Applied(summary: summary, notes: notes, project: editor.project, snapshot: editor.currentSnapshot, live: true)
        }

        var project = try context.loadProject(summary)
        let take = AgentEditTake(project: project, looks: looks)
        let before = EditorSnapshot(keyframes: project.keyframes, editSettings: project.editSettings)
        var after = before
        let notes = try edit(&after, take)
        ZoomKeyframeEditor.resolveOverlaps(&after.keyframes)
        after.keyframes.sort { $0.startTime < $1.startTime }
        // The editor does this for an open take, as part of the same edit.
        after.refreshReframe(take: take, since: before)
        if after != before {
            project.keyframes = after.keyframes
            project.editSettings = after.editSettings
            try save(project)
            context.journal.record(before, actionName: actionName, for: summary.id)
        }
        return Applied(summary: summary, notes: notes, project: project, snapshot: after, live: false)
    }

    private static func requiredOperations(_ arguments: AgentArguments) throws -> [AgentArguments] {
        guard let operations = try arguments.objects("operations"), !operations.isEmpty else {
            throw AgentToolError("operations is required: a list like [{\"op\": \"cut\", \"start\": 2, \"end\": 5}].")
        }
        return operations
    }

    private static func save(_ project: RecorderProject) throws {
        do {
            try ProjectStore.saveEdits(project)
        } catch {
            throw AgentToolError("Couldn't save the edit: \(error.localizedDescription)")
        }
    }

    static func result(
        _ summary: ProjectSummary,
        notes: [String],
        project: RecorderProject,
        snapshot: EditorSnapshot,
        live: Bool
    ) -> JSONValue {
        let timeline = snapshot.editSettings.resolvedTimeline(sourceDuration: project.metadata.duration)
        let value: JSONValue = [
            "take_id": .string(summary.id.uuidString),
            "changes": .array(notes.map { JSONValue.string($0) }),
            "output_duration": AgentTime.json(timeline.outputDuration),
            "segments": .number(Double(timeline.segments.count)),
            "zooms": .number(Double(snapshot.keyframes.count)),
            "text": .number(Double(snapshot.editSettings.textOverlays.count)),
            "blur": .number(Double(snapshot.editSettings.blurRegions.count)),
            "live_in_editor": .bool(live)
        ]
        let undo = live
            ? "It's live in Trace's editor; ⌘Z there or the undo tool reverts it."
            : "Saved; the undo tool reverts it."
        return MCPToolResult.structured(value, summary: (notes + [undo]).joined(separator: " "))
    }
}
