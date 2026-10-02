import Foundation

/// Runs tool calls for `MCPServer`. Failures come back as results with `isError` (see
/// `MCPToolResult`), never as thrown errors, so the agent can read them and retry.
protocol MCPToolExecutor: AnyObject {
    func callTool(name: String, arguments: JSONValue, progress: MCPProgress) async -> JSONValue
}

/// Reports a tool call's progress (0…1, with a short message) when the client asked for
/// it; otherwise it does nothing.
struct MCPProgress {
    let report: @Sendable (Double, String?) -> Void

    static let ignored = MCPProgress { _, _ in }
}

/// The MCP server: both protocol eras (2026-07-28's per-request `_meta`, and the
/// `initialize` handshake of 2025-11-25 and earlier), the tool and prompt catalogs,
/// progress and cancellation. It knows nothing about the transport: feed it one message
/// at a time with `receive`, in the order they arrived, and it hands what to send to
/// `emit` (which must be safe to call from any thread).
actor MCPServer {
    struct Info {
        var name = "trace"
        var title = "Trace"
        var version: String
    }

    /// Versions served statelessly, with the version in each request's `_meta`.
    static let modernVersions = ["2026-07-28"]
    /// Versions negotiated with `initialize`, newest first.
    static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static var supportedVersions: [String] {
        modernVersions + legacyVersions
    }

    static let protocolVersionKey = "io.modelcontextprotocol/protocolVersion"
    static let serverInfoKey = "io.modelcontextprotocol/serverInfo"

    private let info: Info
    private let instructions: String
    private let tools: [MCPTool]
    private let prompts: [MCPPrompt]
    private let executor: MCPToolExecutor
    private let emit: @Sendable (JSONValue) -> Void

    /// What `initialize` settled on; `nil` until a legacy client sends it.
    private(set) var legacyVersion: String?
    private var running: [JSONRPCID: Task<Void, Never>] = [:]
    private var reporters: [JSONRPCID: MCPProgressReporter] = [:]
    private var cancelled: Set<JSONRPCID> = []

    init(
        info: Info,
        instructions: String,
        tools: [MCPTool],
        prompts: [MCPPrompt],
        executor: MCPToolExecutor,
        emit: @escaping @Sendable (JSONValue) -> Void
    ) {
        self.info = info
        self.instructions = instructions
        self.tools = tools
        self.prompts = prompts
        self.executor = executor
        self.emit = emit
    }

    /// Handles one message (one line of the stream, without its newline).
    func receive(_ data: Data) {
        switch JSONRPCIncoming.parse(data) {
        case let .request(id, method, params):
            handleRequest(id: id, method: method, params: params)
        case let .notification(method, params):
            handleNotification(method: method, params: params)
        case .response:
            break
        case let .invalid(id, code, message):
            emit(JSONRPC.error(id: id, code: code, message: message))
        }
    }

    /// Stops every running tool call without answering it (the client went away).
    func cancelAll() {
        for (id, task) in running {
            cancelled.insert(id)
            task.cancel()
        }
    }

    /// Waits until no tool call is running.
    func waitForIdle() async {
        while let task = running.values.first {
            await task.value
        }
    }

    // MARK: - Requests

    private func handleRequest(id: JSONRPCID, method: String, params: JSONValue?) {
        if method == "initialize" {
            initialize(id: id, params: params)
            return
        }

        let modern: Bool
        if let requested = params?["_meta"]?[Self.protocolVersionKey]?.stringValue {
            if Self.modernVersions.contains(requested) {
                modern = true
            } else if Self.legacyVersions.contains(requested) {
                // A legacy version named per request: serve it with legacy semantics.
                modern = false
            } else {
                emit(JSONRPC.error(
                    id: id,
                    code: JSONRPC.unsupportedProtocolVersion,
                    message: "Unsupported protocol version",
                    data: ["supported": versionList, "requested": .string(requested)]
                ))
                return
            }
        } else if legacyVersion != nil || method == "ping" {
            modern = false
        } else {
            let supported = Self.supportedVersions.joined(separator: ", ")
            emit(JSONRPC.error(
                id: id,
                code: JSONRPC.invalidParams,
                message: "Missing _meta \"\(Self.protocolVersionKey)\": send it with every request, or start with initialize. Supported versions: \(supported)."
            ))
            return
        }

        switch method {
        case "server/discover":
            var result = discoverResult
            // Always identify ourselves here, whichever era asked.
            result = Self.adding([Self.serverInfoKey: serverInfo], toMetaOf: result)
            respond(id, result, modern: modern)
        case "ping":
            respond(id, [:], modern: modern)
        case "tools/list":
            respond(id, ["tools": .array(tools.map(\.json))], modern: modern)
        case "tools/call":
            startToolCall(id: id, params: params, modern: modern)
        case "prompts/list":
            respond(id, ["prompts": .array(prompts.map(\.json))], modern: modern)
        case "prompts/get":
            getPrompt(id: id, params: params, modern: modern)
        default:
            emit(JSONRPC.error(id: id, code: JSONRPC.methodNotFound, message: "Method not found: \(method)"))
        }
    }

    private func initialize(id: JSONRPCID, params: JSONValue?) {
        let asked = params?["protocolVersion"]?.stringValue
        let version = asked.flatMap { Self.legacyVersions.contains($0) ? $0 : nil } ?? Self.legacyVersions[0]
        legacyVersion = version
        respond(id, [
            "protocolVersion": .string(version),
            "capabilities": capabilities,
            "serverInfo": serverInfo,
            "instructions": .string(instructions)
        ], modern: false)
    }

    private func startToolCall(id: JSONRPCID, params: JSONValue?, modern: Bool) {
        guard let name = params?["name"]?.stringValue else {
            emit(JSONRPC.error(id: id, code: JSONRPC.invalidParams, message: "tools/call needs a tool name"))
            return
        }
        guard tools.contains(where: { $0.name == name }) else {
            emit(JSONRPC.error(id: id, code: JSONRPC.invalidParams, message: "Unknown tool: \(name)"))
            return
        }
        let arguments = params?["arguments"] ?? .object([:])
        guard arguments.objectValue != nil else {
            emit(JSONRPC.error(id: id, code: JSONRPC.invalidParams, message: "Tool arguments must be an object"))
            return
        }

        var progress = MCPProgress.ignored
        if let token = params?["_meta"]?["progressToken"], token.stringValue != nil || token.intValue != nil {
            let reporter = MCPProgressReporter(token: token, emit: emit)
            reporters[id] = reporter
            progress = MCPProgress { value, message in reporter.report(value, message) }
        }

        let executor = self.executor
        running[id] = Task.detached { [weak self] in
            let result = await executor.callTool(name: name, arguments: arguments, progress: progress)
            await self?.finishToolCall(id: id, result: result, modern: modern)
        }
    }

    private func finishToolCall(id: JSONRPCID, result: JSONValue, modern: Bool) {
        running[id] = nil
        // No progress after the response.
        reporters.removeValue(forKey: id)?.finish()
        guard cancelled.remove(id) == nil else { return }
        respond(id, result, modern: modern)
    }

    private func getPrompt(id: JSONRPCID, params: JSONValue?, modern: Bool) {
        guard let name = params?["name"]?.stringValue,
              let prompt = prompts.first(where: { $0.name == name })
        else {
            emit(JSONRPC.error(id: id, code: JSONRPC.invalidParams, message: "Unknown prompt"))
            return
        }
        var arguments: [String: String] = [:]
        for (key, value) in params?["arguments"]?.objectValue ?? [:] {
            if let string = value.stringValue {
                arguments[key] = string
            } else if !value.isNull {
                arguments[key] = value.text
            }
        }
        for argument in prompt.arguments where argument.required {
            let value = arguments[argument.name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty else {
                emit(JSONRPC.error(id: id, code: JSONRPC.invalidParams, message: "Missing argument: \(argument.name)"))
                return
            }
        }
        respond(id, prompt.messages(for: arguments), modern: modern)
    }

    // MARK: - Notifications

    private func handleNotification(method: String, params: JSONValue?) {
        switch method {
        case "notifications/cancelled":
            guard let raw = params?["requestId"], let id = JSONRPCID(raw), let task = running[id] else { return }
            cancelled.insert(id)
            task.cancel()
        default:
            // notifications/initialized and the rest need no answer.
            break
        }
    }

    // MARK: - Results

    private func respond(_ id: JSONRPCID, _ result: JSONValue, modern: Bool) {
        var decorated = result
        if case var .object(object) = decorated {
            object["resultType"] = "complete"
            decorated = .object(object)
            if modern {
                decorated = Self.adding([Self.serverInfoKey: serverInfo], toMetaOf: decorated)
            }
        }
        emit(JSONRPC.result(id: id, decorated))
    }

    private static func adding(_ entries: [String: JSONValue], toMetaOf result: JSONValue) -> JSONValue {
        guard case var .object(object) = result else { return result }
        var meta = object["_meta"]?.objectValue ?? [:]
        meta.merge(entries) { _, new in new }
        object["_meta"] = .object(meta)
        return .object(object)
    }

    private var versionList: JSONValue {
        .array(Self.supportedVersions.map { .string($0) })
    }

    private var serverInfo: JSONValue {
        ["name": .string(info.name), "title": .string(info.title), "version": .string(info.version)]
    }

    private var capabilities: JSONValue {
        ["tools": ["listChanged": false], "prompts": ["listChanged": false]]
    }

    private var discoverResult: JSONValue {
        ["supportedVersions": versionList, "capabilities": capabilities, "instructions": .string(instructions)]
    }
}

/// Sends `notifications/progress` for one request: values only ever increase, at most
/// four a second (the final one always goes), and nothing once the request has answered.
final class MCPProgressReporter: @unchecked Sendable {
    private let token: JSONValue
    private let emit: @Sendable (JSONValue) -> Void
    private let lock = NSLock()
    private var last: Double = 0
    private var lastSent: TimeInterval = -1
    private var isFinished = false

    static let minimumInterval: TimeInterval = 0.25

    init(token: JSONValue, emit: @escaping @Sendable (JSONValue) -> Void) {
        self.token = token
        self.emit = emit
    }

    func report(_ value: Double, _ message: String?) {
        guard value.isFinite else { return }
        let progress = min(max(value, 0), 1)
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished, progress > last else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard progress >= 1 || lastSent < 0 || now - lastSent >= Self.minimumInterval else { return }
        last = progress
        lastSent = now
        var params: [String: JSONValue] = ["progressToken": token, "progress": .number(progress), "total": 1]
        if let message {
            params["message"] = .string(message)
        }
        emit(JSONRPC.notification(method: "notifications/progress", params: .object(params)))
    }

    func finish() {
        lock.lock()
        isFinished = true
        lock.unlock()
    }
}
