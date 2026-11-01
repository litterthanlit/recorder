import Foundation
import Testing
@testable import RecorderCore

/// Answers bridge calls: `echo` at once, `progress` after reporting half way, `slow` only
/// when cancelled (or after 10 s).
private final class FakeBridgeHandler: AgentBridgeHandler {
    func handle(tool: String, arguments: JSONValue, progress: MCPProgress) async -> JSONValue {
        switch tool {
        case "slow":
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            return MCPToolResult.text("slow")
        case "progress":
            progress.report(0.5, "half")
            return MCPToolResult.text("done")
        default:
            return MCPToolResult.text("echo \(arguments["word"]?.stringValue ?? "")")
        }
    }
}

/// Progress values a client received.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Double, String?)] = []

    func add(_ value: Double, _ message: String?) {
        lock.lock()
        values.append((value, message))
        lock.unlock()
    }

    var all: [(Double, String?)] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

/// A socket path short enough for `sockaddr_un` (a test temp folder isn't).
private func socketPath() -> String {
    "/tmp/trace-\(UUID().uuidString.prefix(8).lowercased()).sock"
}

private func text(of result: JSONValue) -> String? {
    result["content"]?.arrayValue?.first?["text"]?.stringValue
}

@Suite("Agent bridge")
struct AgentBridgeTests {
    @Test func messagesRoundTrip() {
        let messages: [AgentBridgeMessage] = [
            .call(id: 1, tool: "list_takes", arguments: ["limit": 3]),
            .cancel(id: 1),
            .progress(id: 2, value: 0.25, message: "Reading"),
            .progress(id: 2, value: 1, message: nil),
            .result(id: 3, result: MCPToolResult.text("ok"))
        ]
        for message in messages {
            let decoded = AgentBridgeMessage(message.json)
            #expect(decoded == message)
        }
        #expect(AgentBridgeMessage(["type": "call", "id": 1]) == nil)
        #expect(AgentBridgeMessage(["type": "nope", "id": 1]) == nil)
        #expect(AgentBridgeMessage(["type": "cancel"]) == nil)
    }

    @Test func socketPathFallsBackWhenTooLong() {
        let short = URL(fileURLWithPath: "/Users/me/Library/Application Support/Trace")
        #expect(AgentBridgeEndpoint.path(supportDirectory: short, temporaryDirectory: "/tmp")
            == "/Users/me/Library/Application Support/Trace/Agent/agent.sock")

        let long = URL(fileURLWithPath: "/Users/" + String(repeating: "x", count: 90) + "/Library/Application Support/Trace")
        let fallback = AgentBridgeEndpoint.path(supportDirectory: long, temporaryDirectory: "/var/folders/ab/T")
        #expect(fallback == "/var/folders/ab/T/trace-agent.sock")
        #expect(AgentBridgeEndpoint.socketPath.utf8.count <= UnixSocket.maximumPathLength)
    }

    @Test func overlongPathsAreRefused() {
        let path = "/tmp/" + String(repeating: "x", count: 200) + ".sock"
        var failure: Error?
        do {
            _ = try UnixSocket.listen(at: path)
        } catch {
            failure = error
        }
        #expect(failure as? UnixSocket.Failure == UnixSocket.Failure.pathTooLong(path))
    }

    @Test func callsRoundTripWithProgress() async throws {
        let path = socketPath()
        let server = AgentBridgeServer(path: path, handler: FakeBridgeHandler())
        try server.start()
        defer { server.stop() }

        let client = AgentBridgeClient(path: path)
        defer { client.disconnect() }
        let echo = try await client.call(tool: "echo", arguments: ["word": "hi"], progress: .ignored)
        #expect(text(of: echo) == "echo hi")

        let log = ProgressLog()
        let progress = MCPProgress { value, message in log.add(value, message) }
        let done = try await client.call(tool: "progress", arguments: [:], progress: progress)
        #expect(text(of: done) == "done")
        #expect(log.all.map { $0.0 } == [0.5])
        #expect(log.all.first?.1 == "half")

        // Several calls at once on one connection.
        async let first = client.call(tool: "echo", arguments: ["word": "a"], progress: .ignored)
        async let second = client.call(tool: "echo", arguments: ["word": "b"], progress: .ignored)
        let answers = try await [first, second].map { text(of: $0) }
        #expect(answers == ["echo a", "echo b"])
    }

    @Test func cancellingACallStopsWaiting() async throws {
        let path = socketPath()
        let server = AgentBridgeServer(path: path, handler: FakeBridgeHandler())
        try server.start()
        defer { server.stop() }
        let client = AgentBridgeClient(path: path)
        defer { client.disconnect() }

        let call = Task {
            try await client.call(tool: "slow", arguments: [:], progress: .ignored)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        let cancelledAt = Date()
        call.cancel()
        var outcome: Error?
        do {
            _ = try await call.value
        } catch {
            outcome = error
        }
        #expect(outcome is CancellationError)
        #expect(Date().timeIntervalSince(cancelledAt) < 2)
    }

    @Test func stoppingRemovesTheSocketAndCallsFail() async throws {
        let path = socketPath()
        let server = AgentBridgeServer(path: path, handler: FakeBridgeHandler())
        try server.start()
        #expect(UnixSocket.isListening(at: path))
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))

        var failure: Error?
        do {
            _ = try await AgentBridgeClient(path: path).call(tool: "echo", arguments: [:], progress: .ignored)
        } catch {
            failure = error
        }
        #expect(failure as? AgentBridgeClient.Failure == AgentBridgeClient.Failure.unavailable)
    }

    @Test func aLiveServerIsNotReplacedButAStaleSocketIs() throws {
        let path = socketPath()
        let first = AgentBridgeServer(path: path, handler: FakeBridgeHandler())
        try first.start()
        defer { first.stop() }

        var failure: Error?
        do {
            _ = try UnixSocket.listen(at: path)
        } catch {
            failure = error
        }
        #expect(failure as? UnixSocket.Failure == UnixSocket.Failure.alreadyServing(path))

        // A socket file nobody listens on (left by a crash) is taken over.
        let stalePath = socketPath()
        let stale = try UnixSocket.listen(at: stalePath)
        close(stale)
        #expect(FileManager.default.fileExists(atPath: stalePath))
        let replacement = try UnixSocket.listen(at: stalePath)
        close(replacement)
        unlink(stalePath)
    }
}
