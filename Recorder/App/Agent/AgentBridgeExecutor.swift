import AppKit
import Foundation

/// What agents are told when Trace can't take their call.
enum AgentAccessText {
    static let off = """
    Agent access is off in Trace. Ask the person to open Trace › Settings › Agents and turn on \
    "Allow AI agents", then try again.
    """
    static let notListening = """
    Trace is running but isn't taking agent calls. Ask the person to check Trace › Settings › \
    Agents › "Allow AI agents".
    """
    static let didNotStart = """
    Couldn't start Trace. Ask the person to open it once from Applications (it lives in the menu \
    bar), then try again.
    """
    static let busy = "Trace is recording right now. Try again when the take has ended."
}

/// `Trace --mcp`'s tool calls: forwarded to the running app over the bridge, starting
/// the app first when it isn't running. Answers itself, without launching anything,
/// while agent access is off.
final class AgentBridgeExecutor: MCPToolExecutor {
    private let client = AgentBridgeClient(path: AgentBridgeEndpoint.socketPath)

    func callTool(name: String, arguments: JSONValue, progress: MCPProgress) async -> JSONValue {
        // The app's own preferences: this binary is the app's.
        guard AppSettings.load().agentAccessEnabled else {
            return MCPToolResult.error(AgentAccessText.off)
        }
        do {
            return try await client.call(tool: name, arguments: arguments, progress: progress)
        } catch AgentBridgeClient.Failure.unavailable {
            do {
                try await TraceAppLauncher.ensureListening(at: client.path)
                return try await client.call(tool: name, arguments: arguments, progress: progress)
            } catch let failure as AgentToolError {
                return MCPToolResult.error(failure.message)
            } catch is CancellationError {
                return MCPToolResult.error("Cancelled.")
            } catch {
                return MCPToolResult.error(AgentAccessText.notListening)
            }
        } catch is CancellationError {
            return MCPToolResult.error("Cancelled.")
        } catch {
            return MCPToolResult.error("Trace stopped answering (it may have quit or restarted). Try again.")
        }
    }
}

/// Starts Trace for an agent when it isn't running: in the background, without its
/// onboarding window, and at most once per half minute.
enum TraceAppLauncher {
    /// Tells the app it was started for an agent (no onboarding, no panel).
    static let argument = "--launched-for-agent"

    private static let relaunchInterval: TimeInterval = 30
    private static var lastLaunch: Date?

    /// Returns once the app listens at `path`, launching it if no copy is running.
    static func ensureListening(at path: String, timeout: TimeInterval = 20) async throws {
        if UnixSocket.isListening(at: path) {
            return
        }
        if !isAppRunning() {
            try await launch()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if UnixSocket.isListening(at: path) {
                return
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw AgentToolError(isAppRunning() ? AgentAccessText.notListening : AgentAccessText.didNotStart)
    }

    /// Another process of this app is running (this `--mcp` process doesn't count).
    static func isAppRunning() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "app.hypher.recorder"
        let ownID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains {
            $0.processIdentifier != ownID && !$0.isTerminated
        }
    }

    private static func launch() async throws {
        if let lastLaunch, Date().timeIntervalSince(lastLaunch) < relaunchInterval {
            return
        }
        lastLaunch = Date()

        // Two agents starting at once must not start two copies.
        let lock = LaunchLock()
        await lock.acquire(timeout: 10)
        defer { lock.release() }
        guard !isAppRunning() else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.arguments = [argument]
        _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        Log.agent.info("Started Trace for an agent")
    }
}

/// A file lock shared by every `Trace --mcp` process.
private final class LaunchLock {
    private var descriptor: Int32 = -1

    func acquire(timeout: TimeInterval) async {
        let path = AgentBridgeEndpoint.supportDirectory
            .appendingPathComponent(AgentBridgeEndpoint.folderName, isDirectory: true)
            .appendingPathComponent("launch.lock")
            .path
        try? AgentBridgeEndpoint.prepareDirectory(for: path)
        descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}
