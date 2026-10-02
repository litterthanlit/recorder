import Foundation

/// Prompt templates a person can pick in their MCP client (as a slash command, say).
enum AgentPrompts {
    static let all: [MCPPrompt] = [launchDemo, storyboardDemo]

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
            var text = """
            Use the Trace tools to turn \(take) into a polished \(aspect) launch demo of \(product).

            1. Find the take with list_takes, then read it with get_take (apps_in_front shows the apps \
            that were used).
            2. Look before you cut: view_frames (layout "sheet", grid true) to see what's on screen, and \
            analyze_take for dead air, waits, detours into other apps and the beats (clicks, typing).
            3. Write the words: a title (\(product)'s name or a two-to-four-word hook), a tagline (what it \
            does, under eight words) and a caption for each step you can see (three to six words, at most \
            five), each with at: the source time its step starts.
            4. Run make_launch_demo with the title, tagline, captions and aspect "\(aspect)" (add app with \
            \(product)'s app name if the take shows other apps). It trims, cuts pauses and detours, speeds \
            through waits, crops to the app and follows its window, cuts or blurs other apps over it, zooms \
            on clicks, tilts in in 3D, adds transitions and animates the text, then returns a rendered \
            contact sheet.
            5. Check it: view_frames (rendered true) around the title, each caption and each cut. Text should \
            be readable and not cover the action, only \(product) should show, every zoom should land on the \
            right spot, and nothing private should be on screen (hide it with edit_blur). Fix what's off with \
            edit_text, edit_zooms, set_crop, edit_timeline, edit_camera_moves or set_style, or run \
            make_launch_demo again with changes.
            6. Export with export_video (MP4, high quality) and report the file path, the final length and \
            what you changed. undo reverts your last step if the person wants something back.
            """
            if let notes = arguments["notes"], !notes.isEmpty {
                text += "\n\nNotes from the person: \(notes)"
            }
            return text
        }
    )

    /// Walks an agent through directing a take as a storyboard, critiquing it, and
    /// exporting every shape from one timeline.
    static let storyboardDemo = MCPPrompt(
        name: "storyboard_demo",
        title: "Direct an animated demo",
        description: "Storyboard a Trace recording into a polished, animated demo: shots, camera moves and kinetic type, critiqued and fixed, exported at 16:9, 9:16 and 1:1.",
        arguments: [
            MCPPrompt.Argument(name: "product", description: "The product or app being shown", required: true),
            MCPPrompt.Argument(name: "take", description: "Which take: its name or id (default: the latest)"),
            MCPPrompt.Argument(name: "notes", description: "Anything else: the story, the words to use, what to leave out")
        ],
        text: { arguments in
            let product = arguments["product"] ?? "the app"
            let take = arguments["take"].map { "the take \"\($0)\"" } ?? "the latest take"
            var text = """
            Use the Trace tools to direct \(take) as a polished, animated demo of \(product), then export it \
            at 16:9, 9:16 and 1:1 from the same timeline.

            1. Read it: list_takes and get_take (apps_in_front shows the apps used), view_frames (layout \
            "sheet", count 24, grid true) to see every step, and analyze_take for the beats, dead air, \
            detours and other apps' windows over \(product).
            2. Storyboard it, in the recording's order (shots can't overlap or go back): 4 to 8 shots, \
            each 1.5 to 4 s of video. Open with a hook in the first 2 s: a short shot on a striking \
            moment with a two-to-four-word title and a push or zoom. Then land a payoff every 3 to 5 s: \
            a result appearing, a caption landing, a zoom arriving. Give steps a caption of three to six \
            words, vary the camera (zoom, push, pull, pan; a float or orbit on a still screen), speed \
            through waiting (speed 2 to 4), and end on the result as the payoff.
            3. Run render_storyboard with the shots (app "\(product)" if other apps show). Read its \
            warnings and contact sheet.
            4. Critique it: critique_video with fix true and rounds 2, then look at the worst stills it \
            returns. Fix what needs judgment (wording, a better moment, the camera) with edit_text, \
            edit_zooms or a new render_storyboard, and critique again until the score is 80 or more and \
            the hook and rhythm have no issues.
            5. Check the other shapes: critique_video with aspect "9:16", then "1:1" (they're reframed to \
            follow the action). If one needs it, adjust the storyboard and render again.
            6. Export with export_video, aspects ["16:9", "9:16", "1:1"], and report the files, the final \
            length, the scores and what you changed. undo reverts your last step.
            """
            if let notes = arguments["notes"], !notes.isEmpty {
                text += "\n\nNotes from the person: \(notes)"
            }
            return text
        }
    )
}
