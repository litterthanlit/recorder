import Foundation

/// Prompt templates a person can pick in their MCP client (as a slash command, say).
enum AgentPrompts {
    static let all: [MCPPrompt] = [launchDemo]

    /// Walks an agent through turning a raw take into a launch video.
    static let launchDemo = MCPPrompt(
        name: "launch_demo",
        title: "Make a launch demo",
        description: "Turn a Trace recording into a polished, motion-rich launch demo of your app.",
        arguments: [
            MCPPrompt.Argument(name: "product", description: "The product or app being shown", required: true),
            MCPPrompt.Argument(name: "take", description: "Which take: its name or id (default: the latest)"),
            MCPPrompt.Argument(name: "aspect", description: "Video shape: 16:9, 9:16, 1:1, 4:5 or 4:3 (default 16:9)"),
            MCPPrompt.Argument(name: "notes", description: "Anything else: the story, captions to use, what to leave out")
        ],
        text: { arguments in
            let product = arguments["product"] ?? "the app"
            let take = arguments["take"].map { "the take \"\($0)\"" } ?? "the latest take"
            let aspect = arguments["aspect"] ?? "16:9"
            var lines: [String] = [
                "Use the Trace tools to turn \(take) into a polished \(aspect) launch demo of \(product).",
                "",
                "1. Find the take with list_takes, then read it with get_take.",
                "2. Study it: analyze_take for dead air, slow stretches, detours into other apps and the main beats; "
                    + "view_frames (layout \"sheet\", grid on) to see what's on screen.",
                "3. Keep only the story: cut setup, teardown, dead air and anything that isn't \(product). "
                    + "Crop to \(product)'s window if other apps or the desktop are visible.",
                "4. Make it move: auto zooms that land on each click, a short title, a caption per beat, "
                    + "a 3D tilt-in at the start, smooth transitions at cuts and ramped speed-ups through slow parts. "
                    + "make_launch_demo does all of this in one step; refine with the edit tools afterwards.",
                "5. Check the result with view_frames (rendered on): text readable, nothing private on screen, "
                    + "every zoom on the right spot. Fix what's off.",
                "6. Export with export_video (MP4, high quality) and report the file path, the final length and what you changed."
            ]
            if let notes = arguments["notes"], !notes.isEmpty {
                lines += ["", "Notes from the person: \(notes)"]
            }
            return lines.joined(separator: "\n")
        }
    )
}
