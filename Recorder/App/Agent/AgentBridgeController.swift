import Foundation

/// Serves AI agents while Settings › Agents › "Allow AI agents" is on: listens on the
/// bridge socket and hands calls to the tool host.
@MainActor
final class AgentBridgeController: ObservableObject {
    enum Status: Equatable {
        case off
        case listening(agents: Int)
        case failed(String)
    }

    @Published private(set) var status: Status = .off
    let host: AgentToolHost
    private var server: AgentBridgeServer?

    init(host: AgentToolHost) {
        self.host = host
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            start()
        } else {
            stop()
        }
    }

    func start() {
        guard server == nil else { return }
        let path = AgentBridgeEndpoint.socketPath
        let server = AgentBridgeServer(path: path, handler: host)
        server.onConnectionsChanged = { [weak self, weak server] count in
            Task { @MainActor in
                guard let self, let server, self.server === server else { return }
                self.status = .listening(agents: count)
            }
        }
        do {
            try AgentBridgeEndpoint.prepareDirectory(for: path)
            try server.start()
            self.server = server
            status = .listening(agents: 0)
            Log.agent.info("Listening for agents")
        } catch {
            status = .failed(String(describing: error))
            Log.agent.error("Couldn't listen for agents: \(String(describing: error), privacy: .public)")
        }
    }

    func stop() {
        server?.stop()
        server = nil
        status = .off
    }
}

/// Runs agents' tool calls inside the app, on the main actor, where the library and the
/// open editor live.
@MainActor
final class AgentToolHost: AgentBridgeHandler {
    private weak var appState: AppState?
    /// Undo for agents' edits to takes that aren't open.
    let journal = AgentEditJournal()
    let exports = AgentExportJobs()
    let scanner = AgentMediaScanner()

    init(appState: AppState) {
        self.appState = appState
    }

    nonisolated func handle(tool: String, arguments: JSONValue, progress: MCPProgress) async -> JSONValue {
        await run(tool: tool, arguments: AgentArguments(arguments), progress: progress)
    }

    private func run(tool: String, arguments: AgentArguments, progress: MCPProgress) async -> JSONValue {
        guard let appState else {
            return MCPToolResult.error("Trace is quitting.")
        }
        let context = AgentToolContext(
            appState: appState,
            progress: progress,
            journal: journal,
            exports: exports,
            scanner: scanner
        )
        do {
            switch tool {
            case "list_takes":
                return try AgentTakeTools.listTakes(arguments, context)
            case "get_take":
                return try AgentTakeTools.getTake(arguments, context)
            case "analyze_take":
                return try await AgentAnalysisTools.analyzeTake(arguments, context)
            case "view_frames":
                return try await AgentTakeTools.viewFrames(arguments, context)
            case "open_take":
                return try AgentTakeTools.openTake(arguments, context)
            case "make_launch_demo":
                return try await AgentLaunchDemoTools.makeLaunchDemo(arguments, context)
            case "edit_timeline":
                return try AgentEditTools.editTimeline(arguments, context)
            case "edit_zooms":
                return try AgentEditTools.editZooms(arguments, context)
            case "edit_text":
                return try AgentEditTools.editText(arguments, context)
            case "edit_blur":
                return try AgentEditTools.editBlur(arguments, context)
            case "edit_camera_moves":
                return try AgentEditTools.editCameraMoves(arguments, context)
            case "set_crop":
                return try AgentEditTools.setCrop(arguments, context)
            case "set_style":
                return try AgentEditTools.setStyle(arguments, context)
            case "undo":
                return try AgentEditTools.undo(arguments, context)
            case "export_video":
                return try await AgentExportTools.exportVideo(arguments, context)
            case "export_status":
                return try await AgentExportTools.exportStatus(arguments, context)
            default:
                return MCPToolResult.error(
                    "This copy of Trace doesn't have the \(tool) tool. Quit Trace and open it again so it matches the agent tools."
                )
            }
        } catch let error as AgentToolError {
            return MCPToolResult.error(error.message)
        } catch is CancellationError {
            return MCPToolResult.error("Cancelled.")
        } catch {
            Log.agent.error("\(tool, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return MCPToolResult.error("\(tool) failed: \(error.localizedDescription)")
        }
    }
}

/// What a tool sees: the app, how to report progress, and the host's undo journal,
/// export jobs and media scanner.
@MainActor
struct AgentToolContext {
    let appState: AppState
    let progress: MCPProgress
    let journal: AgentEditJournal
    let exports: AgentExportJobs
    let scanner: AgentMediaScanner

    /// The take an agent named (`take_id`), or the newest one.
    func resolveTake(_ arguments: AgentArguments) throws -> ProjectSummary {
        try TakeResolver.resolve(arguments.string("take_id"), in: ProjectStore.listProjects())
    }

    /// The take as it is right now: the open editor's copy (with edits not saved yet),
    /// or the one on disk.
    func load(_ summary: ProjectSummary) throws -> AgentTakeState {
        if let editor = appState.session.editor(for: summary.id) {
            return AgentTakeState(
                project: editor.project,
                keyframes: editor.keyframes,
                editSettings: editor.editSettings,
                editor: editor
            )
        }
        let project = try loadProject(summary)
        return AgentTakeState(project: project, keyframes: project.keyframes, editSettings: project.editSettings, editor: nil)
    }

    /// The take as saved on disk.
    func loadProject(_ summary: ProjectSummary) throws -> RecorderProject {
        do {
            return try ProjectStore.loadProject(from: summary.bundleURL)
        } catch ProjectStoreError.newerFormat {
            throw AgentToolError("\(summary.displayName) was saved by a newer version of Trace; update Trace to edit it.")
        } catch {
            throw AgentToolError("Couldn't read \(summary.displayName): \(error.localizedDescription)")
        }
    }

    /// Heavy work (rendering, analysis, export) waits until a take isn't being recorded.
    func ensureNotRecording() throws {
        if appState.session.isBusy {
            throw AgentToolError(AgentAccessText.busy)
        }
    }
}

/// A take's current state, and the editor showing it if it's open.
struct AgentTakeState {
    let project: RecorderProject
    let keyframes: [ZoomKeyframe]
    let editSettings: ProjectEditSettings
    let editor: ProjectEditor?

    var timeline: EditTimeline {
        editSettings.resolvedTimeline(sourceDuration: project.metadata.duration)
    }
}
