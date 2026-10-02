import CoreGraphics
import Foundation

/// What an edit needs to know about the take besides its edit state.
struct AgentEditTake {
    var duration: TimeInterval
    /// Pixels.
    var sourceSize: CGSize
    var clicks: [ClickEvent]
    /// Built-in and saved looks.
    var looks: [StylePreset]
    /// Which app was in front (empty for takes from before Trace kept it).
    var appFocus: [AppFocusEvent]

    init(
        duration: TimeInterval,
        sourceSize: CGSize,
        clicks: [ClickEvent] = [],
        looks: [StylePreset] = StylePreset.builtIn,
        appFocus: [AppFocusEvent] = []
    ) {
        self.duration = duration
        self.sourceSize = sourceSize
        self.clicks = clicks
        self.looks = looks
        self.appFocus = appFocus
    }

    init(project: RecorderProject, looks: [StylePreset]) {
        self.init(
            duration: project.metadata.duration,
            sourceSize: CGSize(width: project.metadata.width, height: project.metadata.height),
            clicks: project.clickEvents,
            looks: looks,
            appFocus: project.inputs.appFocus
        )
    }
}

/// Reads an agent's times on its chosen clock and turns them into source time, checking
/// they fall inside the recording (or the edited video). Output times always refer to the
/// edit as it was before the tool call, so a batch of operations means what the agent saw.
struct AgentClock {
    let timeBase: AgentTimeBase
    let timeline: EditTimeline
    /// Source seconds.
    let duration: TimeInterval

    init(timeBase: AgentTimeBase, timeline: EditTimeline, duration: TimeInterval) {
        self.timeBase = timeBase
        self.timeline = timeline
        self.duration = duration
    }

    /// How long this clock runs.
    var length: TimeInterval {
        timeBase == .output ? timeline.outputDuration : duration
    }

    var name: String {
        timeBase == .output ? "edited video" : "recording"
    }

    func sourceTime(_ time: TimeInterval) -> TimeInterval {
        timeBase.sourceTime(time, in: timeline)
    }

    /// A source time as this clock shows it.
    func clockTime(forSource time: TimeInterval) -> TimeInterval {
        timeBase == .output ? timeline.outputTimeClamped(forSource: time) : time
    }

    /// One moment (`key`), as source time.
    func instant(_ arguments: AgentArguments, _ key: String) throws -> TimeInterval? {
        guard let time = try arguments.time(key) else { return nil }
        try check(time, time)
        return sourceTime(min(max(time, 0), length))
    }

    /// `{start, end}` or `{start, duration}` as a source span. Missing parts fall back to
    /// `defaultStart` (source time), `defaultDuration` (seconds on this clock, cut short at
    /// the end) or, with `wholeByDefault`, the whole clock.
    func span(
        _ arguments: AgentArguments,
        defaultStart: TimeInterval? = nil,
        defaultDuration: TimeInterval? = nil,
        wholeByDefault: Bool = false
    ) throws -> TimeSpan {
        let start: TimeInterval
        if let given = try arguments.time("start") {
            start = given
        } else if let defaultStart {
            start = clockTime(forSource: defaultStart)
        } else if wholeByDefault {
            start = 0
        } else {
            throw AgentToolError("start is required.")
        }

        let end: TimeInterval
        if let given = try arguments.time("end") {
            end = given
        } else if let length = try arguments.double("duration") {
            guard length > 0 else { throw AgentToolError("duration must be more than 0.") }
            end = start + length
        } else if let defaultDuration {
            end = min(start + defaultDuration, self.length)
        } else if wholeByDefault {
            end = self.length
        } else {
            throw AgentToolError("end (or duration) is required.")
        }

        try check(start, end)
        guard end - start >= 0.05 else {
            throw AgentToolError("end must come after start (got \(AgentArguments.format(start))–\(AgentArguments.format(end)) s).")
        }
        let clampedStart = min(max(start, 0), length)
        let clampedEnd = min(max(end, 0), length)
        return TimeSpan(start: sourceTime(clampedStart), end: sourceTime(clampedEnd))
    }

    private func check(_ start: TimeInterval, _ end: TimeInterval) throws {
        let tolerance = 0.05
        guard start >= -tolerance, end <= length + tolerance else {
            let shown = start == end
                ? "\(AgentArguments.format(start)) s"
                : "\(AgentArguments.format(start))–\(AgentArguments.format(end)) s"
            throw AgentToolError("\(shown) is outside the \(name) (0–\(AgentArguments.format(length)) s).")
        }
    }
}

/// Agents' edits as pure functions of the editor's state. Each checks its arguments,
/// changes `snapshot`, and says in words what it did.
enum AgentEdits {
    /// Undo steps from agents start with this, so the editor (and the `undo` tool) can
    /// tell them from the person's own.
    static let actionPrefix = "Agent: "

    // MARK: - Timeline

    static func editTimeline(
        _ snapshot: inout EditorSnapshot,
        operations: [AgentArguments],
        take: AgentEditTake,
        timeBase: AgentTimeBase
    ) throws -> [String] {
        let before = snapshot.editSettings.resolvedTimeline(sourceDuration: take.duration)
        let clock = AgentClock(timeBase: timeBase, timeline: before, duration: take.duration)
        var timeline = before
        let notes = try eachOperation(operations) { operation, arguments in
            switch operation {
            case "cut":
                let span = try clock.span(arguments)
                guard timeline.excludeSource(span) else {
                    throw AgentToolError("That would cut everything; keep at least part of the video.")
                }
                return "Cut \(describe(span))."
            case "keep_only":
                guard let ranges = try arguments.objects("ranges"), !ranges.isEmpty else {
                    throw AgentToolError("ranges needs at least one {start, end}.")
                }
                let spans = try ranges.map { try clock.span($0) }
                let kept = merged(spans)
                for gap in gaps(between: kept, within: TimeSpan(start: 0, end: take.duration)) {
                    guard timeline.excludeSource(gap) else {
                        throw AgentToolError("Those ranges leave nothing of the current edit.")
                    }
                }
                return "Kept only \(kept.map(describe).joined(separator: ", "))."
            case "trim":
                let start = try clock.instant(arguments, "start")
                let end = try clock.instant(arguments, "end")
                guard start != nil || end != nil else {
                    throw AgentToolError("trim needs start, end or both.")
                }
                if let start, let end, end - start < EditTimeline.minimumSegmentDuration {
                    throw AgentToolError("trim end must come after its start.")
                }
                // Earlier than the edit begins grows it back; later cuts everything before.
                if let start {
                    if start < timeline.trimStart {
                        timeline.setTrimStart(start)
                    } else if start > timeline.trimStart, !timeline.excludeSource(TimeSpan(start: 0, end: start)) {
                        throw AgentToolError("That would cut everything; keep at least part of the video.")
                    }
                }
                if let end {
                    if end > timeline.trimEnd {
                        timeline.setTrimEnd(end, sourceDuration: take.duration)
                    } else if end < timeline.trimEnd, !timeline.excludeSource(TimeSpan(start: end, end: take.duration)) {
                        throw AgentToolError("That would cut everything; keep at least part of the video.")
                    }
                }
                return "Trimmed to \(describe(TimeSpan(start: timeline.trimStart, end: timeline.trimEnd)))."
            case "speed":
                let span = try clock.span(arguments)
                guard let speed = try arguments.double("speed", in: EditTimeline.speedRange) else {
                    throw AgentToolError("speed is required (0.25–16).")
                }
                timeline.applySpeed(speed, toSource: span)
                return "Played \(describe(span)) at \(Timecode.speed(speed))."
            case "reset":
                timeline = EditTimeline(sourceDuration: take.duration)
                // Smooth speed changes are a style; they stay.
                timeline.speedRamp = before.speedRamp
                return "Reset the edit to the whole recording."
            default:
                throw AgentToolError("Unknown op \"\(operation)\". Use cut, keep_only, trim, speed or reset.")
            }
        }
        snapshot.editSettings.setTimeline(timeline.normalized(sourceDuration: take.duration))
        return notes
    }

    // MARK: - Zooms

    static func editZooms(
        _ snapshot: inout EditorSnapshot,
        operations: [AgentArguments],
        take: AgentEditTake,
        timeBase: AgentTimeBase
    ) throws -> [String] {
        let clock = AgentClock(
            timeBase: timeBase,
            timeline: snapshot.editSettings.resolvedTimeline(sourceDuration: take.duration),
            duration: take.duration
        )
        var keyframes = snapshot.keyframes
        var settings = snapshot.editSettings
        // Zooms push in within the crop, where it is while they hold.
        let crop = settings.cropMotion
        let notes = try eachOperation(operations) { operation, arguments in
            switch operation {
            case "auto":
                let preset = try arguments.choice("preset", ZoomPreset.self) ?? settings.zoomPreset
                settings.zoomPreset = preset
                keyframes = ZoomKeyframeEditor.replacingAutoZooms(
                    in: keyframes,
                    clicks: take.clicks,
                    preset: preset,
                    frameSize: take.sourceSize
                )
                let count = keyframes.filter { $0.source == .auto }.count
                return "Made \(count) auto zoom\(count == 1 ? "" : "s") from clicks (\(preset.rawValue)); manual zooms kept."
            case "add":
                let span = try clock.span(arguments, defaultDuration: 2.5)
                guard span.duration >= ZoomKeyframeEditor.minimumSpan else {
                    throw AgentToolError("A zoom needs at least \(ZoomKeyframeEditor.minimumSpan) s.")
                }
                let ease = settings.zoomPreset.settings
                let peak = span.start + min(ease.easeInDuration, span.duration / 3)
                let base = crop.base(at: peak)
                let start = ZoomKeyframe(
                    startTime: span.start,
                    peakTime: peak,
                    endTime: span.end,
                    center: CGPoint(x: base.midX, y: base.midY),
                    scale: ease.zoomScale,
                    source: .manual
                )
                let keyframe = try aimed(start, arguments, requireTarget: true, base: base)
                keyframes.append(ZoomKeyframeEditor.clampKeyframe(keyframe, duration: take.duration))
                return "Added a zoom over \(describe(span)) (zoom_id \(keyframe.id.uuidString))."
            case "update":
                let id = try identifier(arguments, "zoom_id")
                guard let index = keyframes.firstIndex(where: { $0.id == id }) else {
                    throw AgentToolError("No zoom has the zoom_id \(id.uuidString).")
                }
                let current = keyframes[index]
                var updated = ZoomKeyframe(
                    id: current.id,
                    startTime: current.startTime,
                    peakTime: current.peakTime,
                    endTime: current.endTime,
                    center: current.center,
                    scale: current.scale,
                    source: .manual
                )
                if arguments.has("start") || arguments.has("end") || arguments.has("duration") {
                    let length = clock.clockTime(forSource: current.endTime) - clock.clockTime(forSource: current.startTime)
                    let span = try clock.span(arguments, defaultStart: current.startTime, defaultDuration: max(length, 0.25))
                    let lead = min(current.peakTime - current.startTime, span.duration / 2)
                    updated.startTime = span.start
                    updated.peakTime = span.start + max(lead, 0)
                    updated.endTime = span.end
                }
                updated = try aimed(updated, arguments, requireTarget: false, base: crop.base(at: updated.peakTime))
                keyframes[index] = ZoomKeyframeEditor.clampKeyframe(updated, duration: take.duration)
                return "Updated zoom \(id.uuidString)."
            case "remove":
                let before = keyframes.count
                if let ids = try arguments.array("zoom_ids") {
                    let removing = Set(try ids.map { try identifier(AgentArguments(values: ["zoom_id": $0]), "zoom_id") })
                    keyframes.removeAll { removing.contains($0.id) }
                } else {
                    switch try arguments.string("which") ?? "" {
                    case "auto": keyframes.removeAll { $0.source == .auto }
                    case "manual": keyframes.removeAll { $0.source == .manual }
                    case "all": keyframes.removeAll()
                    default: throw AgentToolError("remove needs zoom_ids, or which: \"auto\", \"manual\" or \"all\".")
                    }
                }
                let removed = before - keyframes.count
                return "Removed \(removed) zoom\(removed == 1 ? "" : "s")."
            default:
                throw AgentToolError("Unknown op \"\(operation)\". Use auto, add, update or remove.")
            }
        }
        ZoomKeyframeEditor.resolveOverlaps(&keyframes)
        snapshot.keyframes = keyframes.sorted { $0.startTime < $1.startTime }
        snapshot.editSettings = settings
        return notes
    }

    /// Points `keyframe` at `rect` (fitting it) or `point` (with `scale`), inside `base`
    /// (what the video shows at rest: the crop).
    static func aimed(
        _ keyframe: ZoomKeyframe,
        _ arguments: AgentArguments,
        requireTarget: Bool,
        base: CGRect = SourceCrop.full
    ) throws -> ZoomKeyframe {
        var result = keyframe
        let range = ZoomKeyframeEditor.focusScaleRange
        if let scale = try arguments.double("scale", in: Double(range.lowerBound)...Double(range.upperBound)) {
            result.scale = CGFloat(scale)
            result = ZoomKeyframeEditor.keyframe(result, movingFocusTo: result.center, base: base)
        }
        if let rect = try arguments.object("rect") {
            return ZoomKeyframeEditor.keyframe(result, focusingOn: try AgentCoordinates.sourceRect(rect), base: base)
        }
        if let point = try arguments.object("point") {
            return ZoomKeyframeEditor.keyframe(result, movingFocusTo: try AgentCoordinates.sourcePoint(point), base: base)
        }
        if requireTarget {
            throw AgentToolError("Say where to zoom: rect {x, y, width, height} or point {x, y} (0–1, origin top-left).")
        }
        return result
    }

    // MARK: - Text

    /// Where text goes on the canvas (normalized, origin top-left).
    static let textPositions: [(name: String, center: CGPoint)] = [
        ("top", CGPoint(x: 0.5, y: 0.12)),
        ("upper_third", CGPoint(x: 0.5, y: 0.3)),
        ("center", CGPoint(x: 0.5, y: 0.5)),
        ("lower_third", CGPoint(x: 0.5, y: 0.7)),
        ("bottom", CGPoint(x: 0.5, y: 0.86))
    ]

    /// Long enough to read: about 3 s for five words, between 2 and 6 s.
    static func readingDuration(_ text: String) -> TimeInterval {
        min(max(0.8 + Double(text.count) * 0.06, 2), 6)
    }

    static func defaultCenter(for style: TextOverlay.Style) -> CGPoint {
        switch style {
        case .title: return CGPoint(x: 0.5, y: 0.3)
        case .caption: return CGPoint(x: 0.5, y: 0.82)
        case .callout: return CGPoint(x: 0.5, y: 0.14)
        }
    }

    static func editText(
        _ snapshot: inout EditorSnapshot,
        operations: [AgentArguments],
        take: AgentEditTake,
        timeBase: AgentTimeBase
    ) throws -> [String] {
        let clock = AgentClock(
            timeBase: timeBase,
            timeline: snapshot.editSettings.resolvedTimeline(sourceDuration: take.duration),
            duration: take.duration
        )
        var overlays = snapshot.editSettings.textOverlays
        let notes = try eachOperation(operations) { operation, arguments in
            switch operation {
            case "add":
                let text = try arguments.requiredString("text")
                let style = try arguments.choice("style", TextOverlay.Style.self) ?? .caption
                let span = try clock.span(arguments, defaultDuration: readingDuration(text))
                let overlay = TextOverlay(
                    text: text,
                    span: span,
                    center: try position(arguments) ?? defaultCenter(for: style),
                    style: style,
                    scale: try arguments.double("scale", in: 0.5...2) ?? 1,
                    animation: try arguments.choice("animation", TextAnimation.self) ?? .fade
                )
                overlays.append(overlay)
                return "Added a \(style.rawValue) \"\(shortened(text))\" over \(describe(span)) (text_id \(overlay.id.uuidString))."
            case "update":
                let id = try identifier(arguments, "text_id")
                guard let index = overlays.firstIndex(where: { $0.id == id }) else {
                    throw AgentToolError("No text has the text_id \(id.uuidString).")
                }
                var overlay = overlays[index]
                if let text = try arguments.string("text") {
                    overlay.text = text
                }
                if let style = try arguments.choice("style", TextOverlay.Style.self) {
                    overlay.style = style
                }
                if arguments.has("start") || arguments.has("end") || arguments.has("duration") {
                    let length = clock.clockTime(forSource: overlay.span.end) - clock.clockTime(forSource: overlay.span.start)
                    overlay.span = try clock.span(arguments, defaultStart: overlay.span.start, defaultDuration: max(length, 0.5))
                }
                if let center = try position(arguments) {
                    overlay.center = center
                }
                if let scale = try arguments.double("scale", in: 0.5...2) {
                    overlay.scale = scale
                }
                if let animation = try arguments.choice("animation", TextAnimation.self) {
                    overlay.animation = animation
                }
                overlays[index] = overlay
                return "Updated text \"\(shortened(overlay.text))\"."
            case "remove":
                if try arguments.bool("all") == true {
                    let count = overlays.count
                    overlays.removeAll()
                    return "Removed all \(count) text overlays."
                }
                let id = try identifier(arguments, "text_id")
                guard overlays.contains(where: { $0.id == id }) else {
                    throw AgentToolError("No text has the text_id \(id.uuidString).")
                }
                overlays.removeAll { $0.id == id }
                return "Removed text \(id.uuidString)."
            default:
                throw AgentToolError("Unknown op \"\(operation)\". Use add, update or remove.")
            }
        }
        snapshot.editSettings.textOverlays = overlays
        return notes
    }

    /// `position`: a name ("top", "lower_third"…) or `{x, y}` on the canvas.
    static func position(_ arguments: AgentArguments) throws -> CGPoint? {
        guard let value = arguments.value("position") else { return nil }
        if let name = value.stringValue {
            let wanted = name.lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
            guard let match = textPositions.first(where: { $0.name == wanted }) else {
                let names = textPositions.map { "\"\($0.name)\"" }.joined(separator: ", ")
                throw AgentToolError("position must be one of \(names), or {x, y} (0–1, origin top-left).")
            }
            return match.center
        }
        guard let object = value.objectValue else {
            throw AgentToolError("position must be a name or {x, y}.")
        }
        let point = AgentArguments(values: object)
        guard let x = try point.double("x"), let y = try point.double("y"), (0...1).contains(x), (0...1).contains(y) else {
            throw AgentToolError("position {x, y} must lie within 0–1 (origin top-left).")
        }
        return TextOverlay.clampedCenter(CGPoint(x: x, y: y))
    }

    // MARK: - Blur

    static func editBlur(
        _ snapshot: inout EditorSnapshot,
        operations: [AgentArguments],
        take: AgentEditTake,
        timeBase: AgentTimeBase
    ) throws -> [String] {
        let clock = AgentClock(
            timeBase: timeBase,
            timeline: snapshot.editSettings.resolvedTimeline(sourceDuration: take.duration),
            duration: take.duration
        )
        var regions = snapshot.editSettings.blurRegions
        let notes = try eachOperation(operations) { operation, arguments in
            switch operation {
            case "add":
                guard let rect = try arguments.object("rect") else {
                    throw AgentToolError("rect is required: {x, y, width, height} (0–1, origin top-left).")
                }
                let region = BlurRegion(
                    span: try clock.span(arguments, wholeByDefault: true),
                    rect: BlurRegion.clampedRect(try AgentCoordinates.sourceRect(rect)),
                    kind: try arguments.choice("kind", BlurRegion.Kind.self) ?? .blur,
                    strength: try arguments.double("strength", in: 0...1) ?? 0.6
                )
                regions.append(region)
                return "Hid a box over \(describe(region.span)) (blur_id \(region.id.uuidString))."
            case "update":
                let id = try identifier(arguments, "blur_id")
                guard let index = regions.firstIndex(where: { $0.id == id }) else {
                    throw AgentToolError("No blur box has the blur_id \(id.uuidString).")
                }
                var region = regions[index]
                if let rect = try arguments.object("rect") {
                    region.rect = BlurRegion.clampedRect(try AgentCoordinates.sourceRect(rect))
                }
                if arguments.has("start") || arguments.has("end") || arguments.has("duration") {
                    let length = clock.clockTime(forSource: region.span.end) - clock.clockTime(forSource: region.span.start)
                    region.span = try clock.span(arguments, defaultStart: region.span.start, defaultDuration: max(length, 0.5))
                }
                if let kind = try arguments.choice("kind", BlurRegion.Kind.self) {
                    region.kind = kind
                }
                if let strength = try arguments.double("strength", in: 0...1) {
                    region.strength = strength
                }
                regions[index] = region
                return "Updated blur box \(id.uuidString)."
            case "remove":
                if try arguments.bool("all") == true {
                    let count = regions.count
                    regions.removeAll()
                    return "Removed all \(count) blur boxes."
                }
                let id = try identifier(arguments, "blur_id")
                guard regions.contains(where: { $0.id == id }) else {
                    throw AgentToolError("No blur box has the blur_id \(id.uuidString).")
                }
                regions.removeAll { $0.id == id }
                return "Removed blur box \(id.uuidString)."
            default:
                throw AgentToolError("Unknown op \"\(operation)\". Use add, update or remove.")
            }
        }
        snapshot.editSettings.blurRegions = regions
        return notes
    }

    // MARK: - 3D moves

    static func editCameraMoves(
        _ snapshot: inout EditorSnapshot,
        operations: [AgentArguments],
        take: AgentEditTake,
        timeBase: AgentTimeBase
    ) throws -> [String] {
        let timeline = snapshot.editSettings.resolvedTimeline(sourceDuration: take.duration)
        let clock = AgentClock(timeBase: timeBase, timeline: timeline, duration: take.duration)
        var moves = snapshot.editSettings.cameraMoves
        let notes = try eachOperation(operations) { operation, arguments in
            switch operation {
            case "add":
                guard let kind = try arguments.choice("kind", CameraMoveKind.self) else {
                    throw AgentToolError("kind is required: tilt_in, tilt_out, float, orbit or push_in.")
                }
                // Without a start, a tilt in opens the video and a tilt out closes it.
                let length = min(kind.defaultDuration, timeline.outputDuration)
                let defaultStart: TimeInterval?
                switch kind {
                case .tiltIn:
                    defaultStart = timeline.sourceTime(forOutput: 0)
                case .tiltOut:
                    defaultStart = timeline.sourceTime(forOutput: max(0, timeline.outputDuration - length))
                case .float, .orbit, .pushIn:
                    defaultStart = nil
                }
                let span = try clock.span(arguments, defaultStart: defaultStart, defaultDuration: kind.defaultDuration)
                let move = CameraMove(
                    kind: kind,
                    span: span,
                    intensity: try arguments.double("intensity", in: 0...1) ?? CameraMove.defaultIntensity
                )
                moves.append(move)
                return "Added \(kind.label) over \(describe(span)) (move_id \(move.id.uuidString))."
            case "update":
                let id = try identifier(arguments, "move_id")
                guard let index = moves.firstIndex(where: { $0.id == id }) else {
                    throw AgentToolError("No 3D move has the move_id \(id.uuidString).")
                }
                var move = moves[index]
                if let kind = try arguments.choice("kind", CameraMoveKind.self) {
                    move.kind = kind
                }
                if arguments.has("start") || arguments.has("end") || arguments.has("duration") {
                    let length = clock.clockTime(forSource: move.span.end) - clock.clockTime(forSource: move.span.start)
                    move.span = try clock.span(arguments, defaultStart: move.span.start, defaultDuration: max(length, 0.5))
                }
                if let intensity = try arguments.double("intensity", in: 0...1) {
                    move.intensity = intensity
                }
                moves[index] = move
                return "Updated the \(move.kind.label) move."
            case "remove":
                if try arguments.bool("all") == true {
                    let count = moves.count
                    moves.removeAll()
                    return "Removed all \(count) 3D moves."
                }
                let id = try identifier(arguments, "move_id")
                guard moves.contains(where: { $0.id == id }) else {
                    throw AgentToolError("No 3D move has the move_id \(id.uuidString).")
                }
                moves.removeAll { $0.id == id }
                return "Removed 3D move \(id.uuidString)."
            default:
                throw AgentToolError("Unknown op \"\(operation)\". Use add, update or remove.")
            }
        }
        snapshot.editSettings.cameraMoves = moves
        return notes
    }

    // MARK: - Crop

    /// set_crop: show only part of the recording: an app's window, following it as it
    /// moves (`app`), a fixed `rect` (origin top-left), optionally grown by `margin`, or
    /// all of it (`clear`).
    static func setCrop(_ snapshot: inout EditorSnapshot, arguments: AgentArguments, take: AgentEditTake) throws -> [String] {
        if try arguments.bool("clear") == true {
            guard snapshot.editSettings.sourceCrop != nil else {
                throw AgentToolError("The take isn't cropped; it already shows the whole recording.")
            }
            snapshot.editSettings.sourceCrop = nil
            snapshot.editSettings.cropPath = nil
            return ["Showing the whole recording again."]
        }
        let margin = CGFloat(try arguments.double("margin", in: 0...0.2) ?? 0)
        var notes: [String]
        if let app = try arguments.string("app"), try arguments.bool("follow") ?? true {
            let window = try followedWindow(app, take: take)
            let name = take.appFocus.first { $0.isApp(app) }?.appName ?? app
            guard let home = window.crop, let crop = SourceCrop.sanitized(home.insetBy(dx: -margin, dy: -margin)) else {
                throw AgentToolError("\(name)'s window fills the recording, so there's nothing to crop away.")
            }
            snapshot.editSettings.sourceCrop = crop
            snapshot.editSettings.cropPath = window.path.flatMap { path in
                CropPath(
                    points: path.points.map { CropPath.Point(time: $0.time, rect: $0.rect.insetBy(dx: -margin, dy: -margin)) },
                    app: path.app
                ).sanitized(shape: crop.height / crop.width)
            }
            let size = SourceCrop.contentSize(source: take.sourceSize, crop: crop)
            let pixels = "\(Int(size.width.rounded()))×\(Int(size.height.rounded())) px"
            if snapshot.editSettings.cropPath != nil {
                let moves = window.moves == 1 ? "once" : "\(window.moves) times"
                notes = ["Cropped to \(name)'s window (\(pixels)), following it as it moves (it moved \(moves)); zooms push in within it."]
            } else {
                notes = ["Cropped to \(name)'s window (\(pixels)); it stayed put, so the crop holds still. Zooms push in within it."]
            }
        } else {
            let target: CGRect
            if let app = try arguments.string("app") {
                target = try appWindow(app, take: take)
            } else if let rectArguments = try arguments.object("rect") {
                target = try AgentCoordinates.sourceRect(rectArguments)
            } else {
                throw AgentToolError("set_crop needs app (the app's name), rect {x, y, width, height} (0–1, origin top-left), or clear: true.")
            }
            let rect = target.insetBy(dx: -margin, dy: -margin)
            guard let crop = SourceCrop.sanitized(rect) else {
                throw AgentToolError("That rect is the whole recording; pass clear: true to remove a crop.")
            }
            snapshot.editSettings.sourceCrop = crop
            snapshot.editSettings.cropPath = nil
            let size = SourceCrop.contentSize(source: take.sourceSize, crop: crop)
            notes = ["Cropped to \(Int(size.width.rounded()))×\(Int(size.height.rounded())) px of the recording; zooms now push in within it."]
        }
        if snapshot.editSettings.canvas.aspect != .auto {
            let shape = AgentAspect.name(snapshot.editSettings.canvas.aspect)
            notes.append("The canvas stays \(shape); set_style aspect \"auto\" matches the crop's shape.")
        }
        return notes
    }

    /// The box around everywhere `app`'s front window was in the recording.
    static func appWindow(_ app: String, take: AgentEditTake) throws -> CGRect {
        try checkAppFocus(take)
        guard let window = AppFocusTimeline.windowUnion(of: app, in: take.appFocus) else {
            throw neverShowed(app, take: take)
        }
        return window
    }

    /// `app`'s window as a crop that follows it over the take.
    static func followedWindow(_ app: String, take: AgentEditTake) throws -> WindowCrop {
        try checkAppFocus(take)
        guard let window = WindowCrop.following(app, in: take.appFocus, duration: take.duration) else {
            throw neverShowed(app, take: take)
        }
        return window
    }

    private static func checkAppFocus(_ take: AgentEditTake) throws {
        guard take.appFocus.isEmpty else { return }
        throw AgentToolError(
            "This take doesn't record which app was in front (it's from before Trace kept that). Read the window off view_frames with grid true and pass rect."
        )
    }

    private static func neverShowed(_ app: String, take: AgentEditTake) -> AgentToolError {
        let apps = AppFocusTimeline.quotedNames(take.appFocus, duration: take.duration)
        return AgentToolError("No window of \"\(app)\" showed in the recording. Apps in this take: \(apps).")
    }

    // MARK: - Shared

    /// Runs each `{op: …}`, naming the one that failed in the error.
    static func eachOperation(
        _ operations: [AgentArguments],
        _ body: (String, AgentArguments) throws -> String
    ) throws -> [String] {
        guard !operations.isEmpty else {
            throw AgentToolError("operations is empty.")
        }
        var notes: [String] = []
        for (index, arguments) in operations.enumerated() {
            let operation = try arguments.requiredString("op").lowercased().replacingOccurrences(of: "-", with: "_")
            do {
                notes.append(try body(operation, arguments))
            } catch let error as AgentToolError {
                throw AgentToolError("operations[\(index)] (\(operation)): \(error.message)")
            }
        }
        return notes
    }

    static func identifier(_ arguments: AgentArguments, _ key: String) throws -> UUID {
        let text = try arguments.requiredString(key)
        guard let id = UUID(uuidString: text.trimmingCharacters(in: .whitespaces)) else {
            throw AgentToolError("\(key) \"\(text)\" isn't an id (get_take lists them).")
        }
        return id
    }

    /// Sorted, with overlapping or touching spans joined.
    static func merged(_ spans: [TimeSpan]) -> [TimeSpan] {
        var result: [TimeSpan] = []
        for span in spans.sorted(by: { $0.start < $1.start }) where span.duration > 0 {
            if let last = result.last, span.start <= last.end {
                result[result.count - 1].end = max(last.end, span.end)
            } else {
                result.append(span)
            }
        }
        return result
    }

    /// What `spans` (sorted, not overlapping) leave out of `whole`.
    static func gaps(between spans: [TimeSpan], within whole: TimeSpan) -> [TimeSpan] {
        var result: [TimeSpan] = []
        var covered = whole.start
        for span in spans {
            if span.start > covered {
                result.append(TimeSpan(start: covered, end: min(span.start, whole.end)))
            }
            covered = max(covered, span.end)
        }
        if covered < whole.end {
            result.append(TimeSpan(start: covered, end: whole.end))
        }
        return result.filter { $0.duration > 0.0005 }
    }

    static func describe(_ span: TimeSpan) -> String {
        String(format: "%.2f–%.2f s", span.start, span.end)
    }

    static func shortened(_ text: String) -> String {
        text.count > 40 ? String(text.prefix(39)) + "…" : text
    }
}
