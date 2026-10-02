import Foundation

/// What Trace offers agents over MCP: the tools (in the order `tools/list` shows them) and
/// the instructions every client receives when it connects.
enum AgentToolCatalog {
    static var tools: [MCPTool] {
        [
            listTakes, getTake, analyzeTake, viewFrames,
            editTimeline, setCrop, editZooms, editText, editBlur, editCameraMoves, setStyle, undo,
            exportVideo, exportStatus, openTake
        ]
    }

    static func tool(named name: String) -> MCPTool? {
        tools.first { $0.name == name }
    }

    // MARK: - Shared argument schemas

    static let takeID = Schema.string("Which take: its take_id, its exact name, or \"latest\".")

    static let timeBase = Schema.string(
        "Which clock the times are on: \"source\" (the recording's own, the default) or \"output\" (the edited video).",
        oneOf: AgentTimeBase.allCases.map(\.rawValue)
    )

    // MARK: - Reading

    static let listTakes = MCPTool(
        name: "list_takes",
        title: "List takes",
        description: """
        Lists the recordings in Trace's library, newest first: take_id, name, when it was recorded, \
        its length (duration) and edited length (output_duration), what was captured (display, window \
        or area), the app, whether it's been edited, open in the editor, and the last export's path.
        """,
        inputSchema: Schema.object([
            ("query", Schema.string("Only takes whose name or app contains this text.")),
            ("limit", Schema.integer("At most this many (default 50).", minimum: 1, maximum: 200))
        ]),
        annotations: MCPTool.Annotations(readOnly: true, idempotent: true)
    )

    static let getTake = MCPTool(
        name: "get_take",
        title: "Read a take's edit",
        description: """
        Everything about one take's edit: kept segments (source and output times, speed) and removed \
        source ranges, zooms, text, blur boxes, look, canvas shape and size, audio and what input was \
        recorded. Times are seconds; positions are normalized 0–1 with the origin at the top-left.
        """,
        inputSchema: Schema.object([("take_id", takeID)], required: ["take_id"]),
        annotations: MCPTool.Annotations(readOnly: true, idempotent: true)
    )

    static let analyzeTake = MCPTool(
        name: "analyze_take",
        title: "Find what to cut",
        description: """
        Reads a take's activity (clicks, typing, pointer movement, speech on the microphone, and how \
        much the screen changes) and finds the lead-in before the first action, the tail after the \
        last, dead air (nothing happening) and waits (only the screen moving, like a page loading). \
        Returns them in source time with the beats (click groups, typing, shortcuts) and a suggested \
        edit as edit_timeline operations. Speech is never cut. Reading a long recording takes a while: \
        after wait_seconds (default 40) it returns status "running"; call it again for the result.
        """,
        inputSchema: Schema.object([
            ("take_id", takeID),
            ("wait_seconds", Schema.number("How long to wait for the recording to be read (default 40).", minimum: 0, maximum: 600))
        ], required: ["take_id"]),
        annotations: MCPTool.Annotations(readOnly: true, idempotent: true)
    )

    static let viewFrames = MCPTool(
        name: "view_frames",
        title: "Look at frames",
        description: """
        Shows frames of a take as images: the raw recording (default), or rendered exactly as the export \
        will look (rendered: true, with zooms, background, text and effects). Pick explicit times, or a \
        count spread evenly over the whole take or a range. layout "sheet" (default) tiles up to 24 frames \
        into one labeled contact sheet; "frames" returns up to 6 separate, larger images. grid: true draws \
        a 0–1 coordinate grid (origin top-left) on raw frames, for reading positions to crop, zoom or blur.
        """,
        inputSchema: Schema.object([
            ("take_id", takeID),
            ("times", Schema.array(of: Schema.time("A time to show."), "Times to show (up to 24).", maxItems: 24)),
            ("count", Schema.integer("How many evenly spaced frames (default 12 for a sheet, 4 for frames).", minimum: 1, maximum: 24)),
            ("range", Schema.object([
                ("start", Schema.time("Start of the range.")),
                ("end", Schema.time("End of the range."))
            ], description: "Spread count frames over this range instead of the whole take.")),
            ("time_base", Schema.string(
                "Clock for times and range: \"source\" or \"output\". Defaults to output when rendered, source otherwise.",
                oneOf: AgentTimeBase.allCases.map(\.rawValue)
            )),
            ("rendered", Schema.boolean("Show frames as they will export (default false: the raw recording).")),
            ("layout", Schema.string("One contact sheet, or separate frames.", oneOf: ["sheet", "frames"])),
            ("grid", Schema.boolean("Draw a 0–1 coordinate grid on raw frames (default false)."))
        ], required: ["take_id"]),
        annotations: MCPTool.Annotations(readOnly: true, idempotent: true)
    )

    static let openTake = MCPTool(
        name: "open_take",
        title: "Open in Trace",
        description: "Opens the take in Trace's editor so the person can watch and review it. Later edits to it show up there live.",
        inputSchema: Schema.object([("take_id", takeID)], required: ["take_id"]),
        annotations: MCPTool.Annotations(idempotent: true)
    )

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

    Typical flow: list_takes → analyze_take (what to cut) → view_frames (grid true, to see \
    what's on screen and where) → edit_timeline (start from the suggested operations) → \
    set_crop (only the product's window) → edit_zooms, edit_text, edit_blur, \
    edit_camera_moves, set_style → view_frames rendered true → export_video.
    """
}
