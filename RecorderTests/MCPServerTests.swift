import Foundation
import Testing
@testable import RecorderCore

/// Everything a server emitted, in order (it emits from several tasks).
final class EmittedMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [JSONValue] = []

    func append(_ message: JSONValue) {
        lock.lock()
        messages.append(message)
        lock.unlock()
    }

    var all: [JSONValue] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }

    func response(id: Int) -> JSONValue? {
        all.first { $0["id"]?.intValue == id && $0["method"] == nil }
    }

    func notifications(_ method: String) -> [JSONValue] {
        all.filter { $0["method"]?.stringValue == method }
    }
}

/// Tools for the server tests: `echo` answers at once, `slow` waits until cancelled,
/// `progress` reports progress before answering.
private final class FakeExecutor: MCPToolExecutor {
    private let lock = NSLock()
    private var calls: [(String, JSONValue)] = []

    var recordedCalls: [(String, JSONValue)] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func callTool(name: String, arguments: JSONValue, progress: MCPProgress) async -> JSONValue {
        lock.lock()
        calls.append((name, arguments))
        lock.unlock()

        switch name {
        case "slow":
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return MCPToolResult.text("slow done")
        case "progress":
            progress.report(0.2, "started")
            // Too soon after the last one: dropped.
            progress.report(0.5, "halfway")
            // Not an increase: dropped.
            progress.report(0.1, "backwards")
            // The final value always goes.
            progress.report(1, "done")
            return MCPToolResult.text("finished")
        default:
            return MCPToolResult.text("echo \(arguments["word"]?.stringValue ?? "")")
        }
    }
}

private let modernMeta: JSONValue = [
    "io.modelcontextprotocol/protocolVersion": "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities": [:]
]

private func request(_ id: Int, _ method: String, _ params: [String: JSONValue] = [:], meta: JSONValue? = modernMeta) -> Data {
    var params = params
    if let meta {
        params["_meta"] = meta
    }
    let message: JSONValue = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": .object(params)]
    return message.encoded()
}

private func notification(_ method: String, _ params: [String: JSONValue] = [:]) -> Data {
    let message: JSONValue = ["jsonrpc": "2.0", "method": .string(method), "params": .object(params)]
    return message.encoded()
}

private func makeServer(_ log: EmittedMessages, executor: FakeExecutor = FakeExecutor()) -> MCPServer {
    let tools = ["echo", "slow", "progress"].map { name in
        MCPTool(name: name, title: name.capitalized, description: "Test tool \(name)", inputSchema: Schema.empty)
    }
    return MCPServer(
        info: MCPServer.Info(version: "9.9"),
        instructions: "Use the tools.",
        tools: tools,
        prompts: AgentPrompts.all,
        executor: executor,
        emit: { log.append($0) }
    )
}

@Suite("MCP server")
struct MCPServerTests {
    @Test func legacyClientsInitializeFirst() async throws {
        let log = EmittedMessages()
        let server = makeServer(log)
        await server.receive(request(1, "initialize", [
            "protocolVersion": "2025-06-18",
            "capabilities": [:],
            "clientInfo": ["name": "test", "version": "1"]
        ], meta: nil))
        await server.receive(notification("notifications/initialized"))
        await server.receive(request(2, "tools/list", meta: nil))

        let initialize = try #require(log.response(id: 1)?["result"])
        #expect(initialize["protocolVersion"]?.stringValue == "2025-06-18")
        #expect(initialize["serverInfo"]?["name"]?.stringValue == "trace")
        #expect(initialize["serverInfo"]?["version"]?.stringValue == "9.9")
        #expect(initialize["capabilities"]?["tools"] != nil)
        #expect(initialize["instructions"]?.stringValue == "Use the tools.")
        #expect(initialize["resultType"]?.stringValue == "complete")

        let tools = try #require(log.response(id: 2)?["result"]?["tools"]?.arrayValue)
        #expect(tools.compactMap { $0["name"]?.stringValue } == ["echo", "slow", "progress"])
        // The notification gets no answer.
        #expect(log.all.count == 2)
    }

    @Test func anUnknownLegacyVersionGetsTheNewestOne() async throws {
        let log = EmittedMessages()
        let server = makeServer(log)
        await server.receive(request(1, "initialize", ["protocolVersion": "2099-01-01"], meta: nil))
        let result = try #require(log.response(id: 1)?["result"])
        #expect(result["protocolVersion"]?.stringValue == MCPServer.legacyVersions.first)
    }

    @Test func modernClientsDiscoverTheServer() async throws {
        let log = EmittedMessages()
        let server = makeServer(log)
        await server.receive(request(1, "server/discover"))

        let result = try #require(log.response(id: 1)?["result"])
        let versions = result["supportedVersions"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(versions.contains("2026-07-28"))
        #expect(versions.contains("2025-11-25"))
        #expect(result["_meta"]?[MCPServer.serverInfoKey]?["name"]?.stringValue == "trace")
        #expect(result["capabilities"]?["prompts"] != nil)
        #expect(result["resultType"]?.stringValue == "complete")
    }

    @Test func modernResultsIdentifyTheServer() async throws {
        let log = EmittedMessages()
        let server = makeServer(log)
        await server.receive(request(1, "tools/list"))
        let result = try #require(log.response(id: 1)?["result"])
        #expect(result["_meta"]?[MCPServer.serverInfoKey]?["version"]?.stringValue == "9.9")
        #expect(result["resultType"]?.stringValue == "complete")
    }

    @Test func requestsWithoutAVersionAreRefused() async {
        let log = EmittedMessages()
        let server = makeServer(log)
        await server.receive(request(1, "tools/list", meta: nil))
        #expect(log.response(id: 1)?["error"]?["code"]?.intValue == JSONRPC.invalidParams)
    }

    @Test func unsupportedVersionsListWhatIsSupported() async throws {
        let log = EmittedMessages()
        let server = makeServer(log)
        await server.receive(request(1, "tools/list", meta: ["io.modelcontextprotocol/protocolVersion": "1900-01-01"]))

        let error = try #require(log.response(id: 1)?["error"])
        #expect(error["code"]?.intValue == JSONRPC.unsupportedProtocolVersion)
        #expect(error["data"]?["requested"]?.stringValue == "1900-01-01")
        let supported = error["data"]?["supported"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(supported.contains("2026-07-28"))
    }

    @Test func aLegacyVersionInMetaIsServed() async {
        let log = EmittedMessages()
        let server = makeServer(log)
        await server.receive(request(1, "tools/list", meta: ["io.modelcontextprotocol/protocolVersion": "2025-06-18"]))
        #expect(log.response(id: 1)?["result"]?["tools"] != nil)
    }

    @Test func pingAlwaysAnswers() async {
        let log = EmittedMessages()
        let server = makeServer(log)
        await server.receive(request(1, "ping", meta: nil))
        #expect(log.response(id: 1)?["result"]?["resultType"]?.stringValue == "complete")
    }

    @Test func unknownMethodsAreNotFound() async {
        let log = EmittedMessages()
        let server = makeServer(log)
        await server.receive(request(1, "resources/list"))
        #expect(log.response(id: 1)?["error"]?["code"]?.intValue == JSONRPC.methodNotFound)
    }

    @Test func malformedMessagesGetErrors() async {
        let log = EmittedMessages()
        let server = makeServer(log)
        await server.receive(Data("{oops".utf8))
        await server.receive(Data(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#.utf8))
        await server.receive(Data(#"[{"jsonrpc":"2.0","id":5,"method":"ping"}]"#.utf8))

        let codes = log.all.compactMap { $0["error"]?["code"]?.intValue }
        #expect(codes == [JSONRPC.parseError, JSONRPC.invalidRequest, JSONRPC.invalidRequest])
        #expect(log.all.allSatisfy { $0["id"] == JSONValue.null })
    }

    @Test func toolCallsReachTheExecutor() async throws {
        let log = EmittedMessages()
        let executor = FakeExecutor()
        let server = makeServer(log, executor: executor)
        await server.receive(request(3, "tools/call", ["name": "echo", "arguments": ["word": "hi"]]))
        await server.waitForIdle()

        let result = try #require(log.response(id: 3)?["result"])
        #expect(result["content"]?.arrayValue?.first?["text"]?.stringValue == "echo hi")
        #expect(result["isError"]?.boolValue == false)
        #expect(result["resultType"]?.stringValue == "complete")
        #expect(executor.recordedCalls.map { $0.0 } == ["echo"])
    }

    @Test func unknownToolsAreProtocolErrors() async {
        let log = EmittedMessages()
        let executor = FakeExecutor()
        let server = makeServer(log, executor: executor)
        await server.receive(request(1, "tools/call", ["name": "nope"]))
        await server.waitForIdle()
        #expect(log.response(id: 1)?["error"]?["code"]?.intValue == JSONRPC.invalidParams)
        #expect(executor.recordedCalls.isEmpty)
    }

    @Test func cancelledCallsStopAndAreNotAnswered() async {
        let log = EmittedMessages()
        let server = makeServer(log)
        let started = Date()
        await server.receive(request(7, "tools/call", ["name": "slow"]))
        await server.receive(notification("notifications/cancelled", ["requestId": 7, "reason": "user"]))
        await server.waitForIdle()

        #expect(log.response(id: 7) == nil)
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func progressOnlyIncreasesAndEndsBeforeTheResult() async throws {
        let log = EmittedMessages()
        let server = makeServer(log)
        var meta = modernMeta.objectValue ?? [:]
        meta["progressToken"] = "p1"
        await server.receive(request(4, "tools/call", ["name": "progress"], meta: .object(meta)))
        await server.waitForIdle()

        let updates = log.notifications("notifications/progress")
        #expect(updates.compactMap { $0["params"]?["progress"]?.doubleValue } == [0.2, 1])
        #expect(updates.allSatisfy { $0["params"]?["progressToken"]?.stringValue == "p1" })
        let responseIndex = try #require(log.all.firstIndex { $0["id"]?.intValue == 4 })
        #expect(responseIndex == log.all.count - 1)
    }

    @Test func callsWithoutAProgressTokenReportNothing() async {
        let log = EmittedMessages()
        let server = makeServer(log)
        await server.receive(request(4, "tools/call", ["name": "progress"]))
        await server.waitForIdle()
        #expect(log.notifications("notifications/progress").isEmpty)
        #expect(log.response(id: 4)?["result"] != nil)
    }

    @Test func promptsListAndRender() async throws {
        let log = EmittedMessages()
        let server = makeServer(log)
        await server.receive(request(1, "prompts/list"))
        await server.receive(request(2, "prompts/get", ["name": "launch_demo"]))
        await server.receive(request(3, "prompts/get", ["name": "launch_demo", "arguments": ["product": "Acme", "aspect": "9:16"]]))
        await server.receive(request(4, "prompts/get", ["name": "nope"]))

        let names = log.response(id: 1)?["result"]?["prompts"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        #expect(names == ["launch_demo"])
        #expect(log.response(id: 2)?["error"]?["code"]?.intValue == JSONRPC.invalidParams)
        let text = try #require(log.response(id: 3)?["result"]?["messages"]?.arrayValue?.first?["content"]?["text"]?.stringValue)
        #expect(text.contains("Acme"))
        #expect(text.contains("9:16"))
        #expect(log.response(id: 4)?["error"]?["code"]?.intValue == JSONRPC.invalidParams)
    }
}

@Suite("JSON-RPC messages")
struct JSONRPCMessageTests {
    @Test func classifiesRequestsNotificationsAndResponses() {
        let ping: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "ping"]
        #expect(JSONRPCIncoming.classify(ping) == .request(id: .number(1), method: "ping", params: nil))

        let named: JSONValue = ["jsonrpc": "2.0", "id": "a", "method": "tools/list", "params": [:]]
        #expect(JSONRPCIncoming.classify(named) == .request(id: .string("a"), method: "tools/list", params: .object([:])))

        let initialized: JSONValue = ["jsonrpc": "2.0", "method": "notifications/initialized"]
        #expect(JSONRPCIncoming.classify(initialized) == .notification(method: "notifications/initialized", params: nil))

        let response: JSONValue = ["jsonrpc": "2.0", "id": 9, "result": [:]]
        #expect(JSONRPCIncoming.classify(response) == .response)
    }

    @Test func rejectsBadShapes() {
        let wrongVersion: JSONValue = ["jsonrpc": "1.0", "id": 1, "method": "ping"]
        let arrayParams: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "ping", "params": [1, 2]]
        let fractionalID: JSONValue = ["jsonrpc": "2.0", "id": 1.5, "method": "ping"]
        for message in [wrongVersion, arrayParams, fractionalID] {
            guard case let .invalid(_, code, _) = JSONRPCIncoming.classify(message) else {
                Issue.record("Expected \(message.text) to be invalid")
                continue
            }
            #expect(code == JSONRPC.invalidRequest)
        }
    }

    @Test func buildsResponses() {
        let result = JSONRPC.result(id: .number(3), ["ok": true])
        #expect(result["id"]?.intValue == 3)
        let error = JSONRPC.error(id: nil, code: JSONRPC.parseError, message: "bad")
        #expect(error["id"] == JSONValue.null)
        #expect(error["error"]?["message"]?.stringValue == "bad")
    }
}

@Suite("JSON values")
struct JSONValueTests {
    @Test func roundTripsOnOneLine() throws {
        let value: JSONValue = [
            "text": "line one\nline two",
            "count": 3,
            "ratio": 0.5,
            "flags": [true, false],
            "nothing": .null,
            "path": "a/b"
        ]
        let data = value.encoded()
        #expect(!data.contains(0x0A))
        #expect(try JSONValue.parse(data) == value)

        let text = String(decoding: data, as: UTF8.self)
        // Whole numbers have no fraction, and slashes aren't escaped.
        #expect(text.contains("\"count\":3,"))
        #expect(text.contains("a/b"))
        #expect(value.line().last == 0x0A)
    }

    @Test func nonFiniteNumbersBecomeNull() throws {
        #expect(try JSONValue.parse(JSONValue.number(.nan).encoded()) == .null)
        #expect(JSONValue.finite(.infinity) == .null)
        #expect(JSONValue.finite(2) == .number(2))
    }

    @Test func readsTypedValues() {
        let value: JSONValue = ["n": 3, "f": 2.5, "s": "x", "b": true, "a": [1], "o": ["k": "v"]]
        #expect(value["n"]?.intValue == 3)
        #expect(value["f"]?.intValue == nil)
        #expect(value["f"]?.doubleValue == 2.5)
        #expect(value["s"]?.stringValue == "x")
        #expect(value["b"]?.boolValue == true)
        #expect(value["a"]?.arrayValue?.count == 1)
        #expect(value["o"]?["k"]?.stringValue == "v")
        #expect(value["missing"] == nil)
        #expect(value["s"]?["k"] == nil)
    }

    @Test func convertsCodableTypes() throws {
        struct Sample: Codable, Equatable {
            var name: String
            var span: TimeSpan
        }
        let sample = Sample(name: "intro", span: TimeSpan(start: 1, end: 2.5))
        let json = try JSONValue.encoding(sample)
        #expect(json["span"]?["end"]?.doubleValue == 2.5)
        #expect(try json.decode(Sample.self) == sample)
    }
}

@Suite("Line framing")
struct LineFramingTests {
    @Test func splitsLinesAcrossChunks() throws {
        var buffer = LineBuffer()
        let first = try buffer.append(Data("{\"a\":1}\n{\"b\"".utf8))
        #expect(first == [Data("{\"a\":1}".utf8)])
        let second = try buffer.append(Data(":2}\r\n\n".utf8))
        #expect(second == [Data("{\"b\":2}".utf8)])
        let third = try buffer.append(Data("x\ny\nz".utf8))
        #expect(third == [Data("x".utf8), Data("y".utf8)])
    }

    @Test func dropsOverlongLinesAndRecovers() throws {
        var buffer = LineBuffer(maximumLineLength: 8)
        var failure: Error?
        do {
            _ = try buffer.append(Data("0123456789".utf8))
        } catch {
            failure = error
        }
        #expect(failure as? LineBuffer.Failure == LineBuffer.Failure.lineTooLong)
        let next = try buffer.append(Data("ok\n".utf8))
        #expect(next == [Data("ok".utf8)])
    }

    @Test func writesAndReadsThroughAPipe() {
        var descriptors: [Int32] = [0, 0]
        let status = pipe(&descriptors)
        #expect(status == 0)
        guard status == 0 else { return }

        let payload = Data("hello\n".utf8)
        let wrote = FileDescriptorIO.writeAll(payload, to: descriptors[1])
        close(descriptors[1])
        #expect(wrote)
        #expect(FileDescriptorIO.read(from: descriptors[0]) == payload)
        // The writer closed: end of file.
        #expect(FileDescriptorIO.read(from: descriptors[0]) == nil)
        close(descriptors[0])
    }
}
