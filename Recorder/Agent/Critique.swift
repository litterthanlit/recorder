import CoreGraphics
import Foundation

/// A small grayscale picture of a rendered frame, for judging it: brightness from the
/// top-left, row by row.
struct LumaGrid: Equatable {
    var width: Int
    var height: Int
    /// 0 (black) to 1 (white), `width × height` of them.
    var values: [Double]

    /// Mean brightness and how much it varies (standard deviation) inside `rect`
    /// (normalized, top-left origin); the whole picture for a rect outside it.
    func stats(in rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> (mean: Double, spread: Double) {
        guard width > 0, height > 0, values.count == width * height else { return (0, 0) }
        let clipped = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let area = clipped.isNull ? CGRect(x: 0, y: 0, width: 1, height: 1) : clipped
        let left = min(Int((area.minX * CGFloat(width)).rounded(.down)), width - 1)
        let right = max(min(Int((area.maxX * CGFloat(width)).rounded(.up)), width), left + 1)
        let top = min(Int((area.minY * CGFloat(height)).rounded(.down)), height - 1)
        let bottom = max(min(Int((area.maxY * CGFloat(height)).rounded(.up)), height), top + 1)
        var sum = 0.0
        var squares = 0.0
        var count = 0.0
        for row in top..<bottom {
            for column in left..<right {
                let value = values[row * width + column]
                sum += value
                squares += value * value
                count += 1
            }
        }
        let mean = sum / count
        return (mean, sqrt(max(squares / count - mean * mean, 0)))
    }

    /// How different two pictures are: the mean absolute difference (0 same, 1 opposite).
    func difference(from other: LumaGrid) -> Double {
        guard width == other.width, height == other.height, !values.isEmpty, values.count == other.values.count else { return 1 }
        return zip(values, other.values).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(values.count)
    }
}

/// A moment of the finished video to judge, and why it was picked.
struct CritiqueMoment: Equatable {
    /// Output seconds.
    var output: TimeInterval
    /// Source seconds.
    var source: TimeInterval
    var reason: String
}

/// What the app measured on a still: the frame rendered without text (as a `LumaGrid`)
/// and where each piece of text on it sits.
struct StillMeasurement: Equatable {
    struct Text: Equatable {
        var id: UUID
        /// The plate on the canvas: normalized, top-left origin.
        var frame: CGRect
    }

    var moment: CritiqueMoment
    var backdrop: LumaGrid
    var texts: [Text]
}

/// Something wrong with a still (or with the whole video), and how to fix it.
struct CritiqueIssue: Equatable {
    enum Kind: String {
        case unreadable = "unreadable_text"
        case textTooShort = "text_too_short"
        case textOverAction = "text_over_action"
        case actionOutOfFrame = "action_out_of_frame"
        case soft = "too_zoomed"
        case still = "nothing_changes"
        case blank = "blank_frame"
        case otherApp = "other_app"
        case smallPicture = "small_picture"
        case noHook = "no_hook"
        case longWait = "long_wait"
    }

    var kind: Kind
    /// How much it costs the still's score (0–100).
    var cost: Int
    var message: String
    /// What Trace can do about it; `nil` when it takes judgment.
    var fix: CritiqueFix?
}

/// A fix Trace can make by itself.
enum CritiqueFix: Equatable {
    /// Move a text overlay to a canvas point (normalized, top-left origin).
    case moveText(UUID, to: CGPoint)
    /// Keep a text overlay up until this output time.
    case extendText(UUID, untilOutput: TimeInterval)
    /// Put a title on a dark plate (as a caption) so it reads over anything.
    case plateText(UUID)
    /// Aim a zoom at a source point (normalized, bottom-left origin).
    case aimZoom(UUID, at: CGPoint)
    /// Zoom less close.
    case loosenZoom(UUID, scale: CGFloat)
    /// Bring a still stretch (source time) to life with a 3D move.
    case addMove(CameraMoveKind, span: TimeSpan)
    /// Hide another app's window (normalized source rect, bottom-left origin).
    case blur(CGRect, span: TimeSpan)
    /// Fill the canvas's shape by following the action.
    case reframe

    /// One fix per target: two fixes with the same key would fight.
    var key: String {
        switch self {
        case let .moveText(id, _), let .extendText(id, _), let .plateText(id):
            return "text-\(id.uuidString)-\(self.kindName)"
        case let .aimZoom(id, _), let .loosenZoom(id, _):
            return "zoom-\(id.uuidString)"
        case let .addMove(_, span):
            return "move-\(Int(span.start * 10))"
        case let .blur(_, span):
            return "blur-\(Int(span.start * 10))"
        case .reframe:
            return "reframe"
        }
    }

    private var kindName: String {
        switch self {
        case .moveText: return "move"
        case .extendText: return "extend"
        case .plateText: return "plate"
        default: return ""
        }
    }
}

/// One still, judged.
struct StillScore: Equatable {
    var moment: CritiqueMoment
    /// 0–100.
    var score: Int
    var issues: [CritiqueIssue]
}

/// A critique of the finished video: its stills, worst first on request, and what's wrong
/// with the whole (the hook, the rhythm).
struct Critique: Equatable {
    var stills: [StillScore]
    var overall: [CritiqueIssue]

    /// The mean of the stills' scores, less the whole video's issues.
    var score: Int {
        guard !stills.isEmpty else { return 0 }
        let mean = Double(stills.reduce(0) { $0 + $1.score }) / Double(stills.count)
        return max(0, Int(mean.rounded()) - overall.reduce(0) { $0 + $1.cost } / 2)
    }

    /// The `count` lowest-scoring stills, worst first (only ones with something wrong).
    func worst(_ count: Int) -> [StillScore] {
        Array(stills.filter { !$0.issues.isEmpty }.sorted { $0.score != $1.score ? $0.score < $1.score : $0.moment.output < $1.moment.output }.prefix(count))
    }
}

/// Judges a finished video from stills of it, and makes the fixes it can.
enum Critic {
    /// White text is hard to read on a backdrop brighter than this…
    static let brightBackdrop = 0.62
    /// …or busier than this (spread of brightness).
    static let busyBackdrop = 0.2
    /// Fewer source pixels than this per pixel of the canvas look soft…
    static let softDetail = 0.55
    /// …and a loosened zoom aims for this.
    static let goodDetail = 0.8
    /// Stills this alike (mean difference) look like nothing happens…
    static let sameness = 0.015
    /// …and a stretch of them this long is too still.
    static let stillStretch: TimeInterval = 4
    /// A frame this flat is blank.
    static let blankSpread = 0.025
    /// The recording filling less of the canvas than this looks small.
    static let smallFill = 0.42
    static let maximumMoments = 24

    // MARK: - Where to look

    /// The moments to judge: the opening, each shot (as it starts and in its middle), each
    /// piece of text while it's up, and each zoom as it arrives; at most
    /// `maximumMoments`, at least 0.4 s apart.
    static func moments(_ snapshot: EditorSnapshot, duration: TimeInterval) -> [CritiqueMoment] {
        let timeline = snapshot.editSettings.resolvedTimeline(sourceDuration: duration)
        let length = timeline.outputDuration
        guard length > 0 else { return [] }
        var candidates: [(TimeInterval, String)] = [(min(1, length / 2), "the opening")]
        var output = 0.0
        for (index, segment) in timeline.segments.enumerated() {
            let span = segment.outputDuration
            candidates.append((output + min(0.3, span / 2), "shot \(index + 1) starts"))
            if span > 1.5 {
                candidates.append((output + span / 2, "shot \(index + 1)"))
            }
            output += span
        }
        for overlay in snapshot.editSettings.textOverlays {
            let start = timeline.outputTimeClamped(forSource: overlay.span.start)
            let end = timeline.outputTimeClamped(forSource: overlay.span.end)
            if end > start {
                candidates.append(((start + end) / 2, "text \"\(AgentEdits.shortened(overlay.text))\""))
            }
        }
        for keyframe in snapshot.keyframes {
            if let arrived = timeline.outputTime(forSource: min(keyframe.peakTime + 0.2, keyframe.endTime)) {
                candidates.append((arrived, "a zoom arrives"))
            }
        }
        var picked: [(TimeInterval, String)] = []
        for candidate in candidates.map({ (min(max($0.0, 0), max(length - 0.05, 0)), $0.1) }).sorted(by: { $0.0 < $1.0 }) {
            if let last = picked.last, candidate.0 - last.0 < 0.4 {
                continue
            }
            picked.append(candidate)
        }
        if picked.count > maximumMoments {
            let step = Double(picked.count) / Double(maximumMoments)
            picked = (0..<maximumMoments).map { picked[min(Int(Double($0) * step), picked.count - 1)] }
        }
        return picked.map { CritiqueMoment(output: $0.0, source: timeline.sourceTime(forOutput: $0.0), reason: $0.1) }
    }

    // MARK: - Judging

    /// Scores each still and the whole video. `canvas` is the export's size in pixels;
    /// `analysis` (optional) knows other apps' windows over the app's.
    static func judge(
        _ stills: [StillMeasurement],
        snapshot: EditorSnapshot,
        take: AgentEditTake,
        canvas: CGSize,
        analysis: TakeAnalysis? = nil
    ) -> Critique {
        let settings = snapshot.editSettings
        let timeline = settings.resolvedTimeline(sourceDuration: take.duration)
        let interpolator = ZoomInterpolator(
            keyframes: snapshot.keyframes,
            springEnabled: settings.exportStyle.springCameraEnabled,
            springSettings: settings.zoomPreset.motionFX.spring,
            base: settings.cropBase,
            path: settings.shownCropPath
        )
        let sortedCursor = take.cursor.sorted { $0.timestamp < $1.timestamp }
        var scores: [StillScore] = []
        var previous: (still: StillMeasurement, since: TimeInterval)?
        /// The still holding the current still stretch's issue: a longer stretch moves it on.
        var stretchHolder: Int?

        for still in stills {
            var issues: [CritiqueIssue] = []
            let time = still.moment.source
            let crop = interpolator.cropRect(at: time)
            let cropRect = CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height)
            let contentAspect = (crop.width * take.sourceSize.width) / max(crop.height * take.sourceSize.height, 1)
            let padding = settings.exportStyle.backgroundEnabled ? settings.exportStyle.paddingRatio : 0
            let content = CanvasLayout.contentFrame(canvas: canvas, contentAspect: contentAspect, paddingRatio: padding)

            // Where the action is: a click near this moment, else the pointer.
            var action: CGPoint?
            if let click = take.clicks.min(by: { abs($0.timestamp - time) < abs($1.timestamp - time) }), abs(click.timestamp - time) <= 0.5 {
                action = normalized(click.location, in: take.sourceSize)
            } else if let pointer = sortedCursor.last(where: { $0.timestamp <= time }), time - pointer.timestamp <= 1.5 {
                action = normalized(pointer.location, in: take.sourceSize)
            }
            let onCanvas = action.flatMap { point -> CGPoint? in
                guard cropRect.insetBy(dx: -1e-9, dy: -1e-9).contains(point), canvas.width > 0, canvas.height > 0 else { return nil }
                let x = content.minX + (point.x - cropRect.minX) / cropRect.width * content.width
                let y = content.minY + (1 - (point.y - cropRect.minY) / cropRect.height) * content.height
                return CGPoint(x: x / canvas.width, y: y / canvas.height)
            }
            let zoom = activeZoom(snapshot.keyframes, at: time)

            // Framing: the action in view, not zoomed past the recording's own pixels.
            if let action, onCanvas == nil, let zoom {
                issues.append(CritiqueIssue(
                    kind: .actionOutOfFrame,
                    cost: 30,
                    message: "The action is outside the zoom: it's aimed elsewhere.",
                    fix: .aimZoom(zoom.id, at: action)
                ))
            }
            let detail = Double(crop.width * take.sourceSize.width / max(content.width, 1))
            if detail < softDetail, let zoom {
                let loosened = max(zoom.scale * CGFloat(detail / goodDetail), ZoomKeyframeEditor.focusScaleRange.lowerBound)
                issues.append(CritiqueIssue(
                    kind: .soft,
                    cost: 20,
                    message: String(format: "Zoomed past the recording's sharpness (%.0f%% of a pixel per pixel): it looks soft.", detail * 100),
                    fix: loosened < zoom.scale - 0.05 ? .loosenZoom(zoom.id, scale: loosened) : nil
                ))
            }

            // Text: readable, up long enough, clear of the action.
            for text in still.texts {
                guard let overlay = settings.textOverlays.first(where: { $0.id == text.id }) else { continue }
                let behind = still.backdrop.stats(in: text.frame)
                // Captions and callouts sit on plates; a title is bare white text.
                if overlay.style == .title, behind.mean > brightBackdrop || behind.spread > busyBackdrop {
                    let calmer = calmestSpot(for: text.frame, avoiding: onCanvas, on: still.backdrop, style: overlay.style)
                    let fix: CritiqueFix = calmer.map { .moveText(overlay.id, to: $0) } ?? .plateText(overlay.id)
                    issues.append(CritiqueIssue(
                        kind: .unreadable,
                        cost: 35,
                        message: "\"\(AgentEdits.shortened(overlay.text))\" is hard to read: white text on a \(behind.mean > brightBackdrop ? "bright" : "busy") background.",
                        fix: fix
                    ))
                }
                if let point = onCanvas, text.frame.insetBy(dx: -0.02, dy: -0.02).contains(point) {
                    let clear = calmestSpot(for: text.frame, avoiding: point, on: still.backdrop, style: overlay.style)
                    issues.append(CritiqueIssue(
                        kind: .textOverAction,
                        cost: 30,
                        message: "\"\(AgentEdits.shortened(overlay.text))\" covers the action.",
                        fix: clear.map { .moveText(overlay.id, to: $0) }
                    ))
                }
                let start = timeline.outputTimeClamped(forSource: overlay.span.start)
                let end = timeline.outputTimeClamped(forSource: overlay.span.end)
                let needed = LaunchDemoRecipe.holdDuration(overlay.text)
                if end - start < needed - 0.1 {
                    let room = nextTextStart(after: overlay, in: settings.textOverlays, timeline: timeline) ?? timeline.outputDuration
                    let until = min(start + needed, room - LaunchDemoRecipe.textGap, timeline.outputDuration - LaunchDemoRecipe.endMargin)
                    issues.append(CritiqueIssue(
                        kind: .textTooShort,
                        cost: 25,
                        message: "\"\(AgentEdits.shortened(overlay.text))\" is up \(LaunchDemoRecipe.seconds(end - start)); it needs \(LaunchDemoRecipe.seconds(needed)) to read.",
                        fix: until > end + 0.05 ? .extendText(overlay.id, untilOutput: until) : nil
                    ))
                }
            }

            // The picture: not blank, not too small, not stuck.
            let whole = still.backdrop.stats()
            if whole.spread < blankSpread {
                issues.append(CritiqueIssue(kind: .blank, cost: 30, message: "The frame is nearly blank: cut it or move the shot.", fix: nil))
            }
            let fill = Double(content.width * content.height / max(canvas.width * canvas.height, 1))
            if fill < smallFill {
                let fix: CritiqueFix? = settings.canvas.reframes ? nil : .reframe
                issues.append(CritiqueIssue(
                    kind: .smallPicture,
                    cost: 25,
                    message: String(format: "The recording fills %.0f%% of the frame: reframe to fill the shape.", fill * 100),
                    fix: fix
                ))
            }
            let unchanged = previous.map { still.backdrop.difference(from: $0.still.backdrop) < sameness } ?? false
            if unchanged, let previous {
                let stretch = still.moment.output - previous.since
                if stretch >= stillStretch {
                    let span = TimeSpan(start: timeline.sourceTime(forOutput: previous.since), end: time)
                    let moving = settings.cameraMoves.contains { $0.span.intersection(span) != nil }
                    issues.append(CritiqueIssue(
                        kind: .still,
                        cost: 20,
                        message: "Nothing changes for \(LaunchDemoRecipe.seconds(stretch)): speed it up, cut it or add a move.",
                        fix: moving ? nil : .addMove(.float, span: span)
                    ))
                    // Only the stretch's last still carries it, with all of it.
                    if let holder = stretchHolder {
                        scores[holder].issues.removeAll { $0.kind == .still }
                        scores[holder].score = max(0, 100 - scores[holder].issues.reduce(0) { $0 + $1.cost })
                    }
                    stretchHolder = scores.count
                }
            } else {
                stretchHolder = nil
            }

            // Other apps over the window, unhidden.
            for cover in analysis?.covers ?? [] where cover.action != .keep {
                for piece in cover.pieces where piece.span.contains(time) {
                    let hidden = settings.blurRegions.contains { $0.isActive(at: time) && WindowStack.encloses($0.rect.insetBy(dx: -0.01, dy: -0.01), piece.rect) }
                    if !hidden {
                        issues.append(CritiqueIssue(
                            kind: .otherApp,
                            cost: 30,
                            message: "\(cover.appName)'s window shows over the app.",
                            fix: .blur(piece.rect, span: piece.span)
                        ))
                    }
                }
            }

            let cost = issues.reduce(0) { $0 + $1.cost }
            scores.append(StillScore(moment: still.moment, score: max(0, 100 - cost), issues: issues))
            // While nothing changes, the stretch goes on from where it started.
            if !unchanged {
                previous = (still, still.moment.output)
            }
        }

        return Critique(stills: scores, overall: overallIssues(snapshot: snapshot, timeline: timeline))
    }

    /// The hook and the rhythm: text and motion in the first 2 s, and something new
    /// landing at least every 5 s.
    static func overallIssues(snapshot: EditorSnapshot, timeline: EditTimeline) -> [CritiqueIssue] {
        var issues: [CritiqueIssue] = []
        let settings = snapshot.editSettings
        let texts = settings.textOverlays.map { timeline.outputTimeClamped(forSource: $0.span.start) }
        let zooms = snapshot.keyframes.compactMap { timeline.outputTime(forSource: $0.peakTime) }
        let moves = settings.cameraMoves.map { timeline.outputTimeClamped(forSource: $0.span.start) }
        let hookText = texts.min() ?? .infinity
        let hookMotion = (zooms + moves + snapshot.keyframes.compactMap { timeline.outputTime(forSource: $0.startTime) }).min() ?? .infinity
        if hookText > StoryboardRecipe.hookWindow || hookMotion > StoryboardRecipe.hookWindow {
            issues.append(CritiqueIssue(
                kind: .noHook,
                cost: 20,
                message: "No hook in the first 2 s: open on the most striking moment with a title and a push or zoom.",
                fix: nil
            ))
        }
        var moments = Array(CutTransitions.cutTimes(in: timeline)) + texts + zooms
        moments.append(timeline.outputDuration)
        var last = 0.0
        for moment in moments.filter({ $0 >= 0 }).sorted() {
            if moment - last > StoryboardRecipe.longestWait {
                issues.append(CritiqueIssue(
                    kind: .longWait,
                    cost: 10,
                    message: "Nothing new lands from \(LaunchDemoRecipe.seconds(last)) to \(LaunchDemoRecipe.seconds(moment)): add a caption or zoom, speed it up or cut it. Aim for a payoff every 3–5 s.",
                    fix: nil
                ))
            }
            last = max(last, moment)
        }
        return issues
    }

    // MARK: - Fixing

    /// Makes `fixes` (one per target), returning what changed.
    static func apply(_ fixes: [CritiqueFix], to snapshot: inout EditorSnapshot, take: AgentEditTake) -> [String] {
        var notes: [String] = []
        var done: Set<String> = []
        for fix in fixes where !done.contains(fix.key) {
            done.insert(fix.key)
            var settings = snapshot.editSettings
            let timeline = settings.resolvedTimeline(sourceDuration: take.duration)
            switch fix {
            case let .moveText(id, to):
                guard let index = settings.textOverlays.firstIndex(where: { $0.id == id }) else { continue }
                settings.textOverlays[index].center = TextOverlay.clampedCenter(to)
                notes.append("Moved \"\(AgentEdits.shortened(settings.textOverlays[index].text))\" to a clearer spot.")
            case let .extendText(id, until):
                guard let index = settings.textOverlays.firstIndex(where: { $0.id == id }) else { continue }
                settings.textOverlays[index].span.end = max(settings.textOverlays[index].span.end, timeline.sourceTime(forOutput: until))
                notes.append("Kept \"\(AgentEdits.shortened(settings.textOverlays[index].text))\" up long enough to read.")
            case let .plateText(id):
                guard let index = settings.textOverlays.firstIndex(where: { $0.id == id }) else { continue }
                settings.textOverlays[index].style = .caption
                notes.append("Put \"\(AgentEdits.shortened(settings.textOverlays[index].text))\" on a plate so it reads.")
            case let .aimZoom(id, point):
                guard let index = snapshot.keyframes.firstIndex(where: { $0.id == id }) else { continue }
                let current = snapshot.keyframes[index]
                let manual = ZoomKeyframe(id: current.id, startTime: current.startTime, peakTime: current.peakTime, endTime: current.endTime, center: current.center, scale: current.scale, source: .manual)
                snapshot.keyframes[index] = ZoomKeyframeEditor.keyframe(manual, movingFocusTo: point, base: settings.cropBase(at: current.peakTime))
                notes.append("Aimed a zoom at the action.")
            case let .loosenZoom(id, scale):
                guard let index = snapshot.keyframes.firstIndex(where: { $0.id == id }) else { continue }
                let current = snapshot.keyframes[index]
                let manual = ZoomKeyframe(id: current.id, startTime: current.startTime, peakTime: current.peakTime, endTime: current.endTime, center: current.center, scale: scale, source: .manual)
                snapshot.keyframes[index] = ZoomKeyframeEditor.keyframe(manual, movingFocusTo: current.center, base: settings.cropBase(at: current.peakTime))
                notes.append(String(format: "Eased a zoom back to %.1f× so it stays sharp.", Double(scale)))
            case let .addMove(kind, span):
                settings.cameraMoves.append(CameraMove(kind: kind, span: span, intensity: 0.4))
                notes.append("Added a gentle \(kind.label.lowercased()) where nothing changes.")
            case let .blur(rect, span):
                settings.blurRegions.append(BlurRegion(span: span, rect: rect, kind: .blur, strength: TakeAnalysis.coverBlurStrength))
                notes.append("Blurred another app's window.")
            case .reframe:
                settings.canvas.reframes = true
                notes.append("Reframed to fill the shape.")
            }
            snapshot.editSettings = settings
        }
        return notes
    }

    // MARK: - Helpers

    /// The zoom holding (or moving) at `time`.
    static func activeZoom(_ keyframes: [ZoomKeyframe], at time: TimeInterval) -> ZoomKeyframe? {
        keyframes.first { time >= $0.startTime && time <= $0.endTime }
    }

    /// Where a plate the size of `frame` reads best: a named spot on the calmest, darkest
    /// backdrop, away from `point`; `nil` when no spot is better than where it is.
    static func calmestSpot(for frame: CGRect, avoiding point: CGPoint?, on backdrop: LumaGrid, style: TextOverlay.Style) -> CGPoint? {
        func cost(_ rect: CGRect) -> Double {
            let stats = backdrop.stats(in: rect)
            var value = max(stats.mean - 0.35, 0) + stats.spread * 2
            if let point, rect.insetBy(dx: -0.04, dy: -0.04).contains(point) {
                value += 10
            }
            return value
        }
        let here = cost(frame)
        var best: (center: CGPoint, cost: Double)?
        for spot in AgentEdits.textPositions where spot.name != "center" || style == .title {
            let rect = CGRect(x: frame.minX, y: spot.center.y - frame.height / 2, width: frame.width, height: frame.height)
            guard rect.minY >= 0, rect.maxY <= 1 else { continue }
            let value = cost(rect)
            if value < (best?.cost ?? .infinity) {
                best = (CGPoint(x: frame.midX, y: spot.center.y), value)
            }
        }
        guard let best, best.cost < here - 0.05 else { return nil }
        return best.center
    }

    /// When the next text after `overlay` comes on (output seconds).
    static func nextTextStart(after overlay: TextOverlay, in overlays: [TextOverlay], timeline: EditTimeline) -> TimeInterval? {
        overlays
            .filter { $0.id != overlay.id && $0.span.start > overlay.span.start }
            .map { timeline.outputTimeClamped(forSource: $0.span.start) }
            .min()
    }

    static func normalized(_ point: CGPoint, in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGPoint(x: point.x / size.width, y: point.y / size.height)
    }
}

extension Critique {
    /// As agents read it: output seconds, rects with a top-left origin.
    func json(worst count: Int) -> JSONValue {
        var value: [String: JSONValue] = [
            "score": .number(Double(score)),
            "stills": .number(Double(stills.count)),
            "overall": .array(overall.map { Self.json($0) })
        ]
        value["worst"] = .array(worst(count).map { still -> JSONValue in
            [
                "output_time": AgentTime.json(still.moment.output),
                "source_time": AgentTime.json(still.moment.source),
                "why_picked": .string(still.moment.reason),
                "score": .number(Double(still.score)),
                "issues": .array(still.issues.map { Self.json($0) })
            ]
        })
        let fixable = stills.flatMap(\.issues).filter { $0.fix != nil }.count
        value["fixable_issues"] = .number(Double(fixable))
        return .object(value)
    }

    static func json(_ issue: CritiqueIssue) -> JSONValue {
        var value: [String: JSONValue] = [
            "kind": .string(issue.kind.rawValue),
            "cost": .number(Double(issue.cost)),
            "message": .string(issue.message)
        ]
        value["auto_fix"] = issue.fix.map { JSONValue.string(describe($0)) } ?? JSONValue.null
        return .object(value)
    }

    static func describe(_ fix: CritiqueFix) -> String {
        switch fix {
        case let .moveText(_, to): return String(format: "move the text to y %.2f", Double(to.y))
        case let .extendText(_, until): return "keep the text up until \(LaunchDemoRecipe.seconds(until))"
        case .plateText: return "put the text on a plate"
        case .aimZoom: return "aim the zoom at the action"
        case let .loosenZoom(_, scale): return String(format: "ease the zoom back to %.1f×", Double(scale))
        case let .addMove(kind, _): return "add a gentle \(kind.label.lowercased())"
        case .blur: return "blur the other app's window"
        case .reframe: return "reframe to fill the shape"
        }
    }
}
