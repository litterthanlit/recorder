import Foundation

/// Where the app listens for `Trace --mcp`.
enum AgentBridgeEndpoint {
    static let folderName = "Agent"
    static let socketName = "agent.sock"

    /// `~/Library/Application Support/Trace/Agent/agent.sock`, or the per-user temporary
    /// folder when that path is too long for a socket address.
    static var socketPath: String {
        path(supportDirectory: supportDirectory, temporaryDirectory: userTemporaryDirectory)
    }

    static func path(supportDirectory: URL, temporaryDirectory: String) -> String {
        let preferred = supportDirectory
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(socketName)
            .path
        if preferred.utf8.count <= UnixSocket.maximumPathLength {
            return preferred
        }
        return (temporaryDirectory as NSString).appendingPathComponent("trace-\(socketName)")
    }

    /// The app's own folder in Application Support (where its saved looks live too).
    static var supportDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent(Brand.name, isDirectory: true)
    }

    /// The per-user temporary folder from the system rather than `$TMPDIR`, which the
    /// agent's app may have changed for its subprocesses.
    static var userTemporaryDirectory: String {
        let capacity = Int(PATH_MAX)
        var buffer = [CChar](repeating: 0, count: capacity)
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, capacity)
        guard length > 0, length <= capacity else { return NSTemporaryDirectory() }
        return String(decoding: buffer.prefix(length - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Creates the socket's folder, readable by this user only.
    static func prepareDirectory(for path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directory) {
            try fileManager.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } else if (directory as NSString).lastPathComponent == folderName {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
        }
    }
}

/// The private protocol between `Trace --mcp` and the app: one JSON object per line. The
/// shim sends `call` and `cancel`; the app answers with `progress` and `result`, where a
/// result is already an MCP `CallToolResult`.
enum AgentBridgeMessage: Equatable {
    case call(id: Int, tool: String, arguments: JSONValue)
    case cancel(id: Int)
    case progress(id: Int, value: Double, message: String?)
    case result(id: Int, result: JSONValue)

    var json: JSONValue {
        switch self {
        case let .call(id, tool, arguments):
            return ["type": "call", "id": .number(Double(id)), "tool": .string(tool), "arguments": arguments]
        case let .cancel(id):
            return ["type": "cancel", "id": .number(Double(id))]
        case let .progress(id, value, message):
            var object: [String: JSONValue] = ["type": "progress", "id": .number(Double(id)), "progress": .finite(value)]
            if let message {
                object["message"] = .string(message)
            }
            return .object(object)
        case let .result(id, result):
            return ["type": "result", "id": .number(Double(id)), "result": result]
        }
    }

    init?(_ json: JSONValue) {
        guard let type = json["type"]?.stringValue, let id = json["id"]?.intValue else { return nil }
        switch type {
        case "call":
            guard let tool = json["tool"]?.stringValue else { return nil }
            self = .call(id: id, tool: tool, arguments: json["arguments"] ?? .object([:]))
        case "cancel":
            self = .cancel(id: id)
        case "progress":
            guard let value = json["progress"]?.doubleValue else { return nil }
            self = .progress(id: id, value: value, message: json["message"]?.stringValue)
        case "result":
            guard let result = json["result"] else { return nil }
            self = .result(id: id, result: result)
        default:
            return nil
        }
    }
}

/// Runs the tool calls that arrive over the bridge (the app's tool host). Failures come
/// back as results with `isError`.
protocol AgentBridgeHandler: AnyObject {
    func handle(tool: String, arguments: JSONValue, progress: MCPProgress) async -> JSONValue
}

/// The app's end of the bridge: accepts `Trace --mcp` processes run by this user (and no
/// one else) and runs their calls through `handler`, several at a time.
final class AgentBridgeServer: @unchecked Sendable {
    let path: String
    /// Called on a background queue with the number of connected agents.
    var onConnectionsChanged: ((Int) -> Void)?

    private let handler: AgentBridgeHandler
    private let queue = DispatchQueue(label: "app.hypher.recorder.agent.server")
    private var listener: DispatchSourceRead?
    private var connections: [ObjectIdentifier: AgentBridgeConnection] = [:]
    private var ownsSocketFile = false

    init(path: String, handler: AgentBridgeHandler) {
        self.path = path
        self.handler = handler
    }

    /// Starts listening (throws `UnixSocket.Failure.alreadyServing` if another copy of
    /// the app already is).
    func start() throws {
        let descriptor = try UnixSocket.listen(at: path)
        UnixSocket.setNonBlocking(descriptor)
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptPending(on: descriptor)
        }
        source.setCancelHandler {
            Darwin.close(descriptor)
        }
        queue.sync {
            listener = source
            ownsSocketFile = true
        }
        source.resume()
    }

    /// Stops listening, disconnects every agent and removes the socket file.
    func stop() {
        let removeFile: Bool = queue.sync {
            listener?.cancel()
            listener = nil
            for connection in connections.values {
                connection.close()
            }
            connections.removeAll()
            let owned = ownsSocketFile
            ownsSocketFile = false
            return owned
        }
        if removeFile {
            unlink(path)
        }
    }

    private func acceptPending(on listener: Int32) {
        while true {
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else { return }
            // Only this user's processes; the socket file's permissions say the same.
            guard UnixSocket.peerUserID(client) == getuid() else {
                Darwin.close(client)
                continue
            }
            UnixSocket.configure(client)
            let connection = AgentBridgeConnection(socket: LineSocket(descriptor: client), handler: handler)
            let key = ObjectIdentifier(connection)
            connections[key] = connection
            onConnectionsChanged?(connections.count)
            connection.start { [weak self] in
                self?.queue.async {
                    guard let self else { return }
                    self.connections[key] = nil
                    self.onConnectionsChanged?(self.connections.count)
                }
            }
        }
    }
}

/// One `Trace --mcp` process. Its calls run concurrently; cancelling one stops its task
/// and nothing is sent for it.
final class AgentBridgeConnection: @unchecked Sendable {
    private let socket: LineSocket
    private let handler: AgentBridgeHandler
    private let lock = NSLock()
    private var tasks: [Int: Task<Void, Never>] = [:]

    init(socket: LineSocket, handler: AgentBridgeHandler) {
        self.socket = socket
        self.handler = handler
    }

    func start(onClose: @escaping () -> Void) {
        socket.start(
            onLine: { [weak self] line in
                self?.receive(line)
            },
            onClose: { [weak self] in
                self?.cancelAll()
                onClose()
            }
        )
    }

    func close() {
        socket.close()
    }

    private func receive(_ line: Data) {
        guard let json = try? JSONValue.parse(line), let message = AgentBridgeMessage(json) else { return }
        switch message {
        case let .call(id, tool, arguments):
            run(id: id, tool: tool, arguments: arguments)
        case let .cancel(id):
            lock.lock()
            let task = tasks.removeValue(forKey: id)
            lock.unlock()
            task?.cancel()
        case .progress, .result:
            break
        }
    }

    private func run(id: Int, tool: String, arguments: JSONValue) {
        let socket = self.socket
        let handler = self.handler
        let progress = MCPProgress { value, message in
            socket.send(AgentBridgeMessage.progress(id: id, value: value, message: message).json)
        }
        // Registered before the task can finish: `finish` waits for the lock.
        lock.lock()
        defer { lock.unlock() }
        tasks[id] = Task.detached { [weak self] in
            let result = await handler.handle(tool: tool, arguments: arguments, progress: progress)
            if self?.finish(id) == true {
                socket.send(AgentBridgeMessage.result(id: id, result: result).json)
            }
        }
    }

    /// Forgets a finished call; `false` if it was cancelled in the meantime.
    private func finish(_ id: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tasks.removeValue(forKey: id) != nil
    }

    private func cancelAll() {
        lock.lock()
        let running = Array(tasks.values)
        tasks.removeAll()
        lock.unlock()
        running.forEach { $0.cancel() }
    }
}

/// `Trace --mcp`'s end of the bridge: sends a tool call to the app and waits for its
/// result, passing progress along. Connects on first use and again after the app restarts.
final class AgentBridgeClient: @unchecked Sendable {
    enum Failure: Error, Equatable {
        /// Nothing is listening: the app isn't running, or agent access is off.
        case unavailable
        /// The app went away during the call.
        case disconnected
    }

    private struct Pending {
        let continuation: CheckedContinuation<JSONValue, Error>
        let progress: MCPProgress
    }

    let path: String
    private let lock = NSLock()
    private var socket: LineSocket?
    private var nextID = 1
    private var pending: [Int: Pending] = [:]

    init(path: String) {
        self.path = path
    }

    func call(tool: String, arguments: JSONValue, progress: MCPProgress) async throws -> JSONValue {
        let socket = try connection()
        let id = makeID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                register(id, Pending(continuation: continuation, progress: progress))
                if !socket.send(AgentBridgeMessage.call(id: id, tool: tool, arguments: arguments).json) {
                    finish(id, with: .failure(Failure.disconnected))
                }
            }
        } onCancel: {
            socket.send(AgentBridgeMessage.cancel(id: id).json)
            self.finish(id, with: .failure(CancellationError()))
        }
    }

    /// Drops the connection (the next call connects again).
    func disconnect() {
        lock.lock()
        let current = socket
        socket = nil
        lock.unlock()
        current?.close()
    }

    private func connection() throws -> LineSocket {
        lock.lock()
        defer { lock.unlock() }
        if let socket {
            return socket
        }
        guard let descriptor = try? UnixSocket.connect(to: path) else {
            throw Failure.unavailable
        }
        let socket = LineSocket(descriptor: descriptor, label: "app.hypher.recorder.agent.client")
        self.socket = socket
        socket.start(
            onLine: { [weak self] line in
                self?.receive(line)
            },
            onClose: { [weak self, weak socket] in
                self?.connectionClosed(socket)
            }
        )
        return socket
    }

    private func makeID() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID += 1
        return id
    }

    private func register(_ id: Int, _ entry: Pending) {
        lock.lock()
        pending[id] = entry
        lock.unlock()
    }

    private func receive(_ line: Data) {
        guard let json = try? JSONValue.parse(line), let message = AgentBridgeMessage(json) else { return }
        switch message {
        case let .progress(id, value, text):
            lock.lock()
            let progress = pending[id]?.progress
            lock.unlock()
            progress?.report(value, text)
        case let .result(id, result):
            finish(id, with: .success(result))
        case .call, .cancel:
            break
        }
    }

    private func finish(_ id: Int, with result: Result<JSONValue, Error>) {
        lock.lock()
        let entry = pending.removeValue(forKey: id)
        lock.unlock()
        entry?.continuation.resume(with: result)
    }

    private func connectionClosed(_ closed: LineSocket?) {
        lock.lock()
        if socket === closed || closed == nil {
            socket = nil
        }
        let failed = Array(pending.values)
        pending.removeAll()
        lock.unlock()
        for entry in failed {
            entry.continuation.resume(throwing: Failure.disconnected)
        }
    }
}
