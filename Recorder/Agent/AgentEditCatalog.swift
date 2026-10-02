import Foundation

/// The editing and export tools' descriptions and argument schemas.
extension AgentToolCatalog {
    // MARK: - Shared argument schemas

    static let rect = Schema.object([
        ("x", Schema.number("Left edge, 0–1 from the left.", minimum: 0, maximum: 1)),
        ("y", Schema.number("Top edge, 0–1 from the top.", minimum: 0, maximum: 1)),
        ("width", Schema.number("Width, 0–1.", minimum: 0, maximum: 1)),
        ("height", Schema.number("Height, 0–1.", minimum: 0, maximum: 1))
    ], required: ["x", "y", "width", "height"], description: "A box on the recording, normalized 0–1, origin top-left.")

    static let point = Schema.object([
        ("x", Schema.number("0–1 from the left.", minimum: 0, maximum: 1)),
        ("y", Schema.number("0–1 from the top.", minimum: 0, maximum: 1))
    ], required: ["x", "y"], description: "A point on the recording, normalized 0–1, origin top-left.")

    /// Where text goes: a named spot, or a point on the finished frame.
    static var textPosition: JSONValue {
        let names: [String] = AgentEdits.textPositions.map { $0.name }
        let choices: [JSONValue] = [Schema.string("A named spot.", oneOf: names), point]
        return .object([
            "description": .string("A named spot (\(names.joined(separator: ", "))) or {x, y} on the finished frame (0–1, origin top-left)."),
            "anyOf": .array(choices)
        ])
    }

    static func spanProperties(_ what: String) -> [(String, JSONValue)] {
        [
            ("start", Schema.time("Start of \(what).")),
            ("end", Schema.time("End of \(what).")),
            ("duration", Schema.number("Length in seconds, instead of end.", minimum: 0))
        ]
    }

    static func operations(_ item: JSONValue, _ description: String) -> JSONValue {
        Schema.array(of: item, description + " Applied in order, as one undo step.", maxItems: 100)
    }

    // MARK: - Editing

    static let editTimeline = MCPTool(
        name: "edit_timeline",
        title: "Cut, trim and speed up",
        description: """
        Changes which parts of the recording play and how fast, as one undo step. Ops: \
        "cut" {start, end} removes a range; "keep_only" {ranges: [{start, end}]} removes everything \
        else; "trim" {start?, end?} sets where the video begins and ends; "speed" {start, end, speed \
        0.25–16} plays a range faster or slower; "reset" plays the whole recording again. Times are \
        source time unless time_base is "output"; output times always mean the edit as it was before \
        this call, so several cuts in one call don't shift each other.
        """,
        inputSchema: Schema.object([
            ("take_id", takeID),
            ("time_base", timeBase),
            ("operations", operations(Schema.object([
                ("op", Schema.string("What to do.", oneOf: ["cut", "keep_only", "trim", "speed", "reset"])),
                ("start", Schema.time("Start of the range (cut, speed), or where the video begins (trim).")),
                ("end", Schema.time("End of the range (cut, speed), or where the video ends (trim).")),
                ("duration", Schema.number("Length in seconds, instead of end (cut, speed).", minimum: 0)),
                ("ranges", Schema.array(
                    of: Schema.object(spanProperties("a range to keep")),
                    "keep_only: the ranges to keep.",
                    maxItems: 100
                )),
                ("speed", Schema.number("speed: playback rate, 0.25–16 (2 is twice as fast).", minimum: 0.25, maximum: 16))
            ], required: ["op"]), "Timeline operations, like [{\"op\": \"cut\", \"start\": 0, \"end\": 3.2}]."))
        ], required: ["take_id", "operations"]),
        annotations: MCPTool.Annotations(destructive: true)
    )

    static let setCrop = MCPTool(
        name: "set_crop",
        title: "Show only your app",
        description: """
        Crops the recording to part of the screen, usually the product's window, so the video shows \
        only that: the crop is what plays at rest, zooms push in within it, and the canvas's auto \
        shape and source size follow it. rect is {x, y, width, height} on the recording (0–1, origin \
        top-left; read it off view_frames with grid true); margin grows it a little on each side. \
        clear: true shows the whole recording again. One undo step.
        """,
        inputSchema: Schema.object([
            ("take_id", takeID),
            ("rect", rect),
            ("margin", Schema.number("Grow the rect by this much of the recording on each side (0–0.2).", minimum: 0, maximum: 0.2)),
            ("clear", Schema.boolean("Remove the crop: show the whole recording."))
        ], required: ["take_id"]),
        annotations: MCPTool.Annotations(destructive: true)
    )

    static let editZooms = MCPTool(
        name: "edit_zooms",
        title: "Zooms",
        description: """
        Adds, aims, changes and removes zooms (the camera pushing in on part of the screen), as one \
        undo step. Ops: "auto" {preset?: subtle, demo or punch} remakes the automatic zooms from the \
        recorded clicks (manual zooms stay); "add" {start, end or duration (default 2.5 s), rect, or \
        point with scale 1.1–4} adds a manual zoom; "update" {zoom_id, …} retimes or re-aims one; \
        "remove" {zoom_ids or which: auto, manual or all}. A rect zooms so the box fills the frame.
        """,
        inputSchema: Schema.object([
            ("take_id", takeID),
            ("time_base", timeBase),
            ("operations", operations(Schema.object([
                ("op", Schema.string("What to do.", oneOf: ["auto", "add", "update", "remove"])),
                ("preset", Schema.string("auto: how strong the automatic zooms are.", oneOf: ZoomPreset.allCases.map(\.rawValue))),
                ("zoom_id", Schema.string("update: which zoom (get_take lists them).")),
                ("zoom_ids", Schema.array(of: Schema.string("A zoom_id."), "remove: the zooms to remove.")),
                ("which", Schema.string("remove: a whole group instead of zoom_ids.", oneOf: ["auto", "manual", "all"])),
                ("start", Schema.time("When the zoom starts.")),
                ("end", Schema.time("When the zoom ends.")),
                ("duration", Schema.number("Length in seconds, instead of end.", minimum: 0)),
                ("rect", rect),
                ("point", point),
                ("scale", Schema.number("How far to zoom with point: 1.1–4 (2 shows half the width).", minimum: 1.1, maximum: 4))
            ], required: ["op"]), "Zoom operations."))
        ], required: ["take_id", "operations"]),
        annotations: MCPTool.Annotations(destructive: true)
    )

    static let editText = MCPTool(
        name: "edit_text",
        title: "Text",
        description: """
        Adds, changes and removes text on the video (titles, captions, callouts), as one undo step. \
        Ops: "add" {text, style?: title, caption (default) or callout, start, end or duration (default: \
        long enough to read), position?, scale? 0.5–2, animation? fade, rise, pop, blur or typewriter}; \
        "update" {text_id, …}; "remove" {text_id, or all: true}. position is top, upper_third, center, lower_third or bottom, or {x, y} on the \
        finished frame (0–1, origin top-left). Text is timed on the recording, so it moves with cuts.
        """,
        inputSchema: Schema.object([
            ("take_id", takeID),
            ("time_base", timeBase),
            ("operations", operations(Schema.object([
                ("op", Schema.string("What to do.", oneOf: ["add", "update", "remove"])),
                ("text_id", Schema.string("update, remove: which text (get_take lists them).")),
                ("all", Schema.boolean("remove: every text overlay.")),
                ("text", Schema.string("The words to show.")),
                ("style", Schema.string("title: large bold; caption: on a dark plate; callout: on an accent pill.", oneOf: TextOverlay.Style.allCases.map(\.rawValue))),
                ("start", Schema.time("When it appears.")),
                ("end", Schema.time("When it disappears.")),
                ("duration", Schema.number("How long it shows, instead of end.", minimum: 0)),
                ("position", textPosition),
                ("scale", Schema.number("Size, 0.5–2 (1 is the style's own).", minimum: 0.5, maximum: 2)),
                ("animation", Schema.string(
                    "How it comes on and goes off: fade (default), rise (rises into place), pop (springs up), blur (comes into focus) or typewriter (types on).",
                    oneOf: TextAnimation.allCases.map(\.rawValue)
                ))
            ], required: ["op"]), "Text operations."))
        ], required: ["take_id", "operations"]),
        annotations: MCPTool.Annotations(destructive: true)
    )

    static let editBlur = MCPTool(
        name: "edit_blur",
        title: "Hide private details",
        description: """
        Blurs or pixelates boxes on the recording (emails, names, keys, notifications), as one undo step. \
        Ops: "add" {rect, start?, end? (default: the whole take), kind?: blur or pixelate, strength? 0–1}; \
        "update" {blur_id, …}; "remove" {blur_id, or all: true}. Find the boxes with view_frames and grid: true.
        """,
        inputSchema: Schema.object([
            ("take_id", takeID),
            ("time_base", timeBase),
            ("operations", operations(Schema.object([
                ("op", Schema.string("What to do.", oneOf: ["add", "update", "remove"])),
                ("blur_id", Schema.string("update, remove: which box (get_take lists them).")),
                ("all", Schema.boolean("remove: every box.")),
                ("rect", rect),
                ("start", Schema.time("When the box starts hiding.")),
                ("end", Schema.time("When it stops.")),
                ("duration", Schema.number("How long, instead of end.", minimum: 0)),
                ("kind", Schema.string("How it hides.", oneOf: BlurRegion.Kind.allCases.map(\.rawValue))),
                ("strength", Schema.number("0–1 (default 0.6).", minimum: 0, maximum: 1))
            ], required: ["op"]), "Blur operations."))
        ], required: ["take_id", "operations"]),
        annotations: MCPTool.Annotations(destructive: true)
    )

    static let editCameraMoves = MCPTool(
        name: "edit_camera_moves",
        title: "3D camera moves",
        description: """
        Moves the recording's frame in 3D, as one undo step. Ops: "add" {kind, start?, end or duration, \
        intensity? 0–1 (default 0.6)}; "update" {move_id, …}; "remove" {move_id, or all: true}. Kinds: \
        tilt_in (starts tilted back and settles flat; without a start it opens the video), tilt_out \
        (tilts away; without a start it closes the video), float (hovers, turning gently), orbit (swings \
        from side to side) and push_in (moves slowly closer). Best on a background with some padding.
        """,
        inputSchema: Schema.object([
            ("take_id", takeID),
            ("time_base", timeBase),
            ("operations", operations(Schema.object([
                ("op", Schema.string("What to do.", oneOf: ["add", "update", "remove"])),
                ("move_id", Schema.string("update, remove: which move (get_take lists them).")),
                ("all", Schema.boolean("remove: every move.")),
                ("kind", Schema.string("The move.", oneOf: CameraMoveKind.allCases.map(\.rawValue))),
                ("start", Schema.time("When it starts.")),
                ("end", Schema.time("When it ends.")),
                ("duration", Schema.number("How long, instead of end.", minimum: 0)),
                ("intensity", Schema.number("How strong, 0–1 (default 0.6).", minimum: 0, maximum: 1))
            ], required: ["op"]), "3D move operations."))
        ], required: ["take_id", "operations"]),
        annotations: MCPTool.Annotations(destructive: true)
    )

    static let setStyle = MCPTool(
        name: "set_style",
        title: "Look and shape",
        description: """
        Sets how the video looks, as one undo step: a saved look first (look: "Midnight", "Studio Light", \
        "Vivid", "Minimal", "Vertical Social" or one the person saved), then any setting on top: background, \
        the canvas shape (aspect) and size (resolution), padding around the recording, corner radius, shadow, \
        cursor, click effects, motion blur, the spring camera, keystrokes, a watermark, audio levels, and \
        motion at cuts: a transition, smooth speed changes, audio fades and muting sped-up parts. \
        Pass only what should change.
        """,
        inputSchema: Schema.object(styleProperties, required: ["take_id"]),
        annotations: MCPTool.Annotations(destructive: true)
    )

    static var styleProperties: [(String, JSONValue)] {
        [
            ("take_id", takeID),
            ("look", Schema.string("A look by name: Midnight, Studio Light, Vivid, Minimal, Vertical Social, or one the person saved.")),
            ("background", Schema.object([
                ("wallpaper", Schema.string("A built-in wallpaper.", oneOf: WallpaperPreset.allCases.map(\.rawValue))),
                ("color", Schema.string("A solid colour, \"#RRGGBB\".")),
                ("from", Schema.string("Gradient start colour, \"#RRGGBB\".")),
                ("to", Schema.string("Gradient end colour, \"#RRGGBB\".")),
                ("angle", Schema.number("Gradient angle in degrees.", minimum: 0, maximum: 360)),
                ("kind", Schema.string("\"none\": the recording fills the frame, no background.", oneOf: ["none", "wallpaper", "gradient", "solid"]))
            ], description: "Behind the recording: one of wallpaper, color, from+to, or kind \"none\".")),
            ("zoom_preset", Schema.string("How strong automatic zooms are; remakes them.", oneOf: ZoomPreset.allCases.map(\.rawValue))),
            ("aspect", Schema.string("Canvas shape.", oneOf: AgentAspect.names.map { $0.1 })),
            ("resolution", Schema.string("Canvas size.", oneOf: ["720p", "1080p", "1440p", "4k", "source"])),
            ("padding", Schema.number("Space around the recording, 0–0.3 of the frame.", minimum: 0, maximum: 0.3)),
            ("corner_radius", Schema.number("Rounded corners, 0–48.", minimum: 0, maximum: 48)),
            ("shadow", Schema.boolean("Drop shadow under the recording.")),
            ("show_cursor", Schema.boolean("Draw the recorded cursor.")),
            ("cursor_size", Schema.number("Cursor size, 0.5–3×.", minimum: 0.5, maximum: 3)),
            ("hide_idle_cursor", Schema.boolean("Fade the cursor out when it rests.")),
            ("cursor_smoothing", Schema.boolean("Smooth the cursor's path.")),
            ("click_bounce", Schema.boolean("Pulse the cursor on clicks.")),
            ("click_ripples", Schema.boolean("Ripples where clicks land.")),
            ("spotlight", Schema.boolean("Dim around the cursor.")),
            ("motion_blur", Schema.boolean("Blur fast camera moves.")),
            ("spring_camera", Schema.boolean("Springy, physical zoom motion.")),
            ("keystrokes", Schema.string("Show keys pressed.", oneOf: KeystrokeFilter.allCases.map(\.rawValue))),
            ("watermark", Schema.string("Corner text; \"\" removes it.")),
            ("microphone_volume", Schema.number("0–2 (1 is as recorded).", minimum: 0, maximum: 2)),
            ("system_audio_volume", Schema.number("0–2 (1 is as recorded).", minimum: 0, maximum: 2)),
            ("cut_transition", Schema.string(
                "A transition at every cut: zoom_blur (push in), whip (fast pan), blur_dip, or none.",
                oneOf: CutTransitionStyle.allCases.map(\.rawValue) + ["none"]
            )),
            ("cut_transition_duration", Schema.number("How long each transition lasts, 0.15–1 s (default 0.4).", minimum: 0.15, maximum: 1)),
            ("smooth_speed_changes", Schema.boolean("Ease into and out of sped-up parts instead of jumping speed.")),
            ("cut_audio_fades", Schema.boolean("Short audio fades either side of each cut, so cuts don't click.")),
            ("mute_sped_up_audio", Schema.boolean("Silence parts played faster than 2.5×."))
        ]
    }

    static let undo = MCPTool(
        name: "undo",
        title: "Undo",
        description: """
        Undoes the last agent edit to a take. With the take open in Trace, only steps named "Agent: …" \
        are undone, so the person's own edits are safe; force: true undoes their last step too.
        """,
        inputSchema: Schema.object([
            ("take_id", takeID),
            ("force", Schema.boolean("Undo the last step even if the person made it (default false)."))
        ], required: ["take_id"]),
        annotations: MCPTool.Annotations(destructive: true)
    )

    // MARK: - Export

    static let exportVideo = MCPTool(
        name: "export_video",
        title: "Export",
        description: """
        Exports the take as edited: mp4 (plays everywhere), hevc (smaller), prores (for video editors) \
        or gif (at most 30 s). Unset options use the person's export settings. Waits up to wait_seconds \
        (default 45) and returns the file; a longer export returns status "running" and an export_id \
        for export_status. Never replaces an existing file.
        """,
        inputSchema: Schema.object([
            ("take_id", takeID),
            ("format", Schema.string("File type.", oneOf: ExportFormat.allCases.map(\.rawValue))),
            ("quality", Schema.string("mp4 and hevc only: web (small), high, or studio (near-lossless).", oneOf: ExportQuality.allCases.map(\.rawValue))),
            ("fps", Schema.integer("Frame rate: 24, 30 or 60 (default: the recording's).", minimum: 24, maximum: 60)),
            ("folder", Schema.string("Where to save it: a full path like ~/Desktop (default: the export folder in Trace's settings).")),
            ("file_name", Schema.string("File name without extension (default: the take's name).")),
            ("wait_seconds", Schema.number("How long to wait before returning an export_id (default 45).", minimum: 0, maximum: 600))
        ], required: ["take_id"]),
        annotations: MCPTool.Annotations()
    )

    static let exportStatus = MCPTool(
        name: "export_status",
        title: "Export progress",
        description: """
        Checks on an export from export_video (default: the latest): waits up to wait_seconds \
        (default 30) for it to finish, then reports queued, running, done (with the file), failed or \
        cancelled. cancel: true stops it.
        """,
        inputSchema: Schema.object([
            ("export_id", Schema.string("The export_id from export_video.")),
            ("wait_seconds", Schema.number("How long to wait for it to finish (default 30).", minimum: 0, maximum: 600)),
            ("cancel", Schema.boolean("Stop the export."))
        ]),
        annotations: MCPTool.Annotations(readOnly: false, idempotent: true)
    )
}
