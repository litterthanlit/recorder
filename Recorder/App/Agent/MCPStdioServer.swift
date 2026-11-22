import Foundation

/// `Trace --mcp`: an MCP server on stdin and stdout for agents (Claude Code, Claude
/// Desktop, Cursor), started by the agent's app as a subprocess. It never creates the
/// app's UI or state: protocol work happens here, and tool calls go to the running app.
///
/// stdout carries only MCP messages, one per line; diagnostics go to stderr.
enum MCPStdioServer {
    static let argument = "--mcp"

    static func run() -> Never {
        // An agent that goes away mid-write must not kill the process.
        signal(SIGPIPE, SIG_IGN)

        // Move the JSON-RPC stdout stream onto a private descriptor and redirect fd 1
        // to stderr so stray print() or framework logs can never corrupt the framing.
        let protocolStdout: Int32
        let duplicated = dup(STDOUT_FILENO)
        if duplicated >= 0 {
            _ = fcntl(duplicated, F_SETFD, FD_CLOEXEC)
            _ = dup2(STDERR_FILENO, STDOUT_FILENO)
            protocolStdout = duplicated
        } else {
            protocolStdout = STDOUT_FILENO
        }

        let output = DispatchQueue(label: "app.hypher.recorder.mcp.stdout")
        let server = MCPServer(
            info: MCPServer.Info(version: appVersion),
            instructions: AgentToolCatalog.instructions,
            tools: AgentToolCatalog.tools,
            prompts: AgentPrompts.all,
            executor: AgentBridgeExecutor(),
            emit: { message in
                let line = message.line()
                output.async {
                    FileDescriptorIO.writeAll(line, to: protocolStdout)
                }
            }
        )

        // Bound unread stdin messages in memory if a client floods lines faster than we drain.
        let pendingBudget = DispatchSemaphore(value: 128)
        let lines = AsyncStream<Data> { continuation in
            Thread.detachNewThread {
                var buffer = LineBuffer()
                while let chunk = FileDescriptorIO.read(from: STDIN_FILENO) {
                    do {
                        for line in try buffer.append(chunk) {
                            pendingBudget.wait()
                            continuation.yield(line)
                        }
                    } catch {
                        MCPStdioServer.log("Dropped a message longer than \(buffer.maximumLineLength) bytes")
                    }
                }
                continuation.finish()
            }
        }

        Task {
            for await line in lines {
                pendingBudget.signal()
                await server.receive(line)
            }
            // The agent closed stdin: stop promptly, after what's already been written.
            await server.cancelAll()
            output.sync {}
            if protocolStdout != STDOUT_FILENO {
                Darwin.close(protocolStdout)
            }
            exit(0)
        }
        dispatchMain()
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static func log(_ message: String) {
        FileDescriptorIO.writeAll(Data("trace-mcp: \(message)\n".utf8), to: STDERR_FILENO)
    }
}
