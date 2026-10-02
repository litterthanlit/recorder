import Foundation

/// How to connect an agent to `Trace --mcp`, for Settings › Agents.
enum AgentSetup {
    static let serverName = "trace"

    /// Claude Code, for every project: `claude mcp add --scope user trace -- <path> --mcp`.
    static func claudeCodeCommand(executable: String) -> String {
        "claude mcp add --scope user \(serverName) -- \(shellQuoted(executable)) --mcp"
    }

    /// The `mcpServers` entry for Claude Desktop, Cursor and other MCP clients.
    static func clientConfig(executable: String) -> String {
        let config: [String: Any] = [
            "mcpServers": [
                serverName: [
                    "command": executable,
                    "args": ["--mcp"]
                ]
            ]
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Single quotes when the path has anything a shell would split or expand.
    static func shellQuoted(_ text: String) -> String {
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+@%:,"))
        guard text.unicodeScalars.contains(where: { !plain.contains($0) }) else { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Something to say to the agent once it's connected.
    static let examplePrompt = "Turn my latest Trace take into a 16:9 launch demo of my app: cut the dead time, keep only the app on screen, add a title and smooth zooms, then export an MP4."
}
