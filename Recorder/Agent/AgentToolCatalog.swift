import Foundation

/// What Trace offers agents over MCP: the tools (in the order `tools/list` shows them) and
/// the instructions every client receives when it connects.
enum AgentToolCatalog {
    static var tools: [MCPTool] {
        []
    }

    static func tool(named name: String) -> MCPTool? {
        tools.first { $0.name == name }
    }

    static let instructions = """
    Trace is a macOS screen recorder for product demos. These tools edit its recordings \
    ("takes") into polished videos and export them. Trace must be running with \
    Settings › Agents › "Allow AI agents" turned on.

    Conventions:
    - Times are seconds on the recording's own clock ("source time") unless you pass \
    time_base "output" (the edited video's clock). Times can be numbers or "m:ss.s" strings.
    - Rectangles and points on the recording are normalized 0–1 with the origin at the \
    TOP-LEFT, like the frames view_frames returns (turn on its grid to read positions).
    - Each edit tool call is one undo step named "Agent: …"; undo reverts your last one.
    - Check your work: view_frames with rendered true shows frames exactly as they will export.

    Typical flow: list_takes → analyze_take → view_frames → edits (or make_launch_demo) → \
    view_frames rendered → export_video.
    """
}
