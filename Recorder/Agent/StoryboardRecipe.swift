import CoreGraphics
import Foundation

/// What render_storyboard made of a storyboard.
struct StoryboardReport: Equatable {
    struct Shot: Equatable {
        var role: Storyboard.Shot.Role
        /// Source seconds.
        var source: TimeSpan
        /// Output seconds.
        var output: TimeSpan
        var speed: Double
        var camera: String
        var textID: UUID?
        /// Output seconds.
        var textOutput: TimeSpan?
        var warnings: [String] = []
    }

    var shots: [Shot] = []
    var outputDuration: TimeInterval = 0
    /// When text and camera motion first start (output seconds).
    var hookText: TimeInterval?
    var hookMotion: TimeInterval?
    /// Output seconds where something new lands: a cut, text, a zoom arriving, a result.
    var payoffs: [TimeInterval] = []
    /// The longest stretch without one.
    var longestWait: TimeSpan?
    var changes: [String] = []
    /// What doesn't follow the storyboard's rules (the hook, the rhythm, shot lengths).
    var warnings: [String] = []
    var suggestions: [String] = []

    var hookOK: Bool {
        guard let hookText else { return false }
        return hookText <= StoryboardRecipe.hookWindow && (hookMotion ?? .infinity) <= StoryboardRecipe.hookWindow
    }
}

/// Turns a storyboard into the edit, as one step: the timeline is the shots (each at its
/// speed, smooth speed changes), the camera follows each shot's move, its text comes on
/// as kinetic type, the video is cropped to the app (following its window, other apps
/// hidden) and reframed for the shape, with transitions, motion blur and the spring
/// camera. Zooms, text and 3D moves are replaced; blur boxes stay.
struct StoryboardRecipe {
    var storyboard: Storyboard

    /// A zoom takes this long (video seconds) to arrive.
    static let arrival: TimeInterval = 0.5
    /// Moves start or end this far outside their shot when the time there is cut, so the
    /// cut lands on them mid-move or settled.
    static let roll: TimeInterval = 0.6
    static let pushScale: CGFloat = 1.35
    static let pullScale: CGFloat = 1.8
    /// The hook is in the first seconds…
    static let hookWindow: TimeInterval = 2
    /// …then something new lands at least this often.
    static let longestWait: TimeInterval = 5
    /// Shots shorter than this flash by; longer ones drag.
    static let shortShot: TimeInterval = 0.8
    static let longShot: TimeInterval = 6
    static let transitionDuration: TimeInterval = 0.3

    func apply(to snapshot: inout EditorSnapshot, take: AgentEditTake, analysis: TakeAnalysis) throws -> StoryboardReport {
        var report = StoryboardReport()
        var settings = snapshot.editSettings
        let shots = storyboard.shots

        if let name = storyboard.look {
            let look = try AgentEdits.look(named: name, in: take.looks)
            look.apply(to: &settings)
            report.changes.append("Applied the \(look.name) look.")
        }
        if let aspect = storyboard.aspect {
            settings.canvas.aspect = aspect
            settings.canvas.reframes = storyboard.reframe ?? true
            report.changes.append("Shape \(AgentAspect.name(aspect)).")
        } else if let reframe = storyboard.reframe {
            settings.canvas.reframes = reframe
        }

        // The timeline: only the shots, each at its speed.
        var timeline = EditTimeline(sourceDuration: take.duration)
        timeline.speedRamp = SpeedRamp.defaultRamp
        for gap in AgentEdits.gaps(between: shots.map(\.span), within: TimeSpan(start: 0, end: take.duration)) {
            timeline.excludeSource(gap)
        }
        for shot in shots where abs(shot.speed - 1) > 1e-6 {
            timeline.applySpeed(shot.speed, toSource: shot.span)
        }
        timeline = timeline.normalized(sourceDuration: take.duration)
        settings.setTimeline(timeline)
        let recorded = shots.reduce(0) { $0 + $1.span.duration }
        report.changes.append(
            "Built the edit from \(shots.count) shot\(shots.count == 1 ? "" : "s"): \(LaunchDemoRecipe.seconds(recorded)) of the recording → \(LaunchDemoRecipe.seconds(timeline.outputDuration))."
        )

        // Only the app, as the launch demo does it. The shots are chosen, so other apps
        // over the window are blurred rather than cut, however much they hide.
        var options = LaunchDemoOptions()
        options.app = storyboard.app
        options.cropToApp = storyboard.cropToApp
        let launch = LaunchDemoRecipe(options: options)
        var cropping = LaunchDemoReport()
        var shown = analysis
        shown.covers = analysis.covers.map { cover in
            var blurred = cover
            if cover.action == .cut {
                blurred.action = .blur
            }
            return blurred
        }
        launch.cropToApp(&settings, take: take, analysis: shown, report: &cropping)
        launch.hideCovers(&settings, analysis: shown, report: &cropping)
        report.changes += cropping.changes
        report.suggestions += cropping.suggestions
        for (index, shot) in shots.enumerated() {
            let away = analysis.offApp.compactMap { $0.intersection(shot.span) }.filter { $0.duration > 0.2 }
            if let first = away.first, let app = analysis.focusApp {
                let total = away.reduce(0) { $0 + $1.duration }
                report.warnings.append(
                    "shots[\(index)] shows \(LaunchDemoRecipe.seconds(total)) with another app in front of \(app) (from \(LaunchDemoRecipe.seconds(first.start))): move the shot, or split it around that."
                )
            }
            for cover in analysis.covers where cover.action == .cut && cover.span.intersection(shot.span) != nil {
                report.warnings.append(
                    "shots[\(index)]: \(cover.appName) hides much of \(analysis.focusApp ?? "the app") from \(LaunchDemoRecipe.seconds(cover.span.start)) (blurred); pick another moment if it shouldn't show."
                )
            }
        }

        // Aim against the picture itself; the reframing comes after, from these zooms.
        settings.reframe = nil
        var keyframes: [ZoomKeyframe] = []
        var moves: [CameraMove] = []
        var described: [String] = []
        let autoZooms = ZoomKeyframeEditor.replacingAutoZooms(in: [], clicks: take.clicks, preset: settings.zoomPreset, frameSize: take.sourceSize)
        for (index, shot) in shots.enumerated() {
            let made = camera(for: shot, index: index, take: take, analysis: analysis, settings: settings, autoZooms: autoZooms)
            keyframes += made.keyframes
            described.append(made.description)
            if let kind = shot.camera.threeD {
                moves.append(CameraMove(kind: kind, span: shot.span))
            }
        }
        ZoomKeyframeEditor.resolveOverlaps(&keyframes)
        keyframes.sort { $0.startTime < $1.startTime }
        settings.cameraMoves = moves
        let moveCount = shots.filter { $0.camera.move != .hold }.count
        report.changes.append("Camera: \(moveCount) shot\(moveCount == 1 ? "" : "s") with a move, \(moves.count) in 3D; zooms and 3D moves replaced.")

        // Kinetic type.
        settings.textOverlays.removeAll()
        var textSpans: [UUID: TimeSpan] = [:]
        var shotResults: [StoryboardReport.Shot] = []
        for (index, shot) in shots.enumerated() {
            let output = TimeSpan(
                start: timeline.outputTimeClamped(forSource: shot.span.start),
                end: timeline.outputTimeClamped(forSource: shot.span.end)
            )
            var result = StoryboardReport.Shot(
                role: shot.role,
                source: shot.span,
                output: output,
                speed: shot.speed,
                camera: described[index],
                textID: nil,
                textOutput: nil
            )
            if output.duration < Self.shortShot {
                result.warnings.append("It flashes by (\(LaunchDemoRecipe.seconds(output.duration))): give it more of the recording or slow it down.")
            } else if output.duration > Self.longShot {
                result.warnings.append("It runs \(LaunchDemoRecipe.seconds(output.duration)): speed it up or split it so something new lands every few seconds.")
            }
            if let text = shot.text {
                let start = min(output.start + text.at, max(output.end - LaunchDemoRecipe.minimumCaption, output.start))
                let wanted = text.hold ?? LaunchDemoRecipe.holdDuration(text.text)
                let end = min(start + wanted, output.end)
                if end - start < wanted - 0.05 {
                    result.warnings.append(
                        "Its text needs \(LaunchDemoRecipe.seconds(wanted)) but the shot leaves \(LaunchDemoRecipe.seconds(end - start)): slow the shot, lengthen it or shorten the text."
                    )
                }
                let span = TimeSpan(start: timeline.sourceTime(forOutput: start), end: timeline.sourceTime(forOutput: end))
                let overlay = TextOverlay(text: text.text, span: span, center: text.position, style: text.style, animation: text.animation)
                settings.textOverlays.append(overlay)
                result.textID = overlay.id
                result.textOutput = TimeSpan(start: start, end: end)
                textSpans[overlay.id] = result.textOutput
            }
            shotResults.append(result)
        }
        let textCount = settings.textOverlays.count
        if textCount > 0 {
            report.changes.append("Text: \(textCount) piece\(textCount == 1 ? "" : "s") of kinetic type, replacing what was there.")
        }

        // Motion and sound at the cuts.
        settings.exportStyle.motionBlurEnabled = true
        settings.exportStyle.springCameraEnabled = true
        settings.audio.cutFades = true
        settings.audio.muteSpedUp = true
        if let style = storyboard.transition {
            settings.cutTransition = CutTransition(style: style, duration: Self.transitionDuration)
            report.changes.append("\(style.label) transitions between shots, with audio fades.")
        } else {
            settings.cutTransition = nil
        }

        // Reframed for the shape, following these zooms; zooms aimed at a box are fitted
        // again to the reframed picture so the box still shows whole.
        if settings.canvas.reframes {
            settings.reframe = Reframer.reframe(settings, keyframes: keyframes, take: take)
            if settings.reframe != nil {
                for shot in shots {
                    guard let target = shot.camera.target, target.width > 0, shot.camera.scale == nil,
                          [.zoom, .push].contains(shot.camera.move)
                    else { continue }
                    for keyIndex in keyframes.indices where keyframes[keyIndex].peakTime >= shot.span.start && keyframes[keyIndex].peakTime <= shot.span.end + 1e-6 {
                        keyframes[keyIndex] = ZoomKeyframeEditor.keyframe(
                            keyframes[keyIndex],
                            focusingOn: target,
                            base: settings.cropBase(at: keyframes[keyIndex].peakTime)
                        )
                    }
                }
                report.changes.append("Reframed for \(AgentAspect.name(settings.canvas.aspect)): the frame follows the action.")
            }
        }

        snapshot.keyframes = keyframes
        snapshot.editSettings = settings
        report.shots = shotResults
        report.outputDuration = timeline.outputDuration
        check(&report, keyframes: keyframes, timeline: timeline, analysis: analysis)
        return report
    }

    // MARK: - Camera

    /// The zooms for one shot, and how to describe them.
    func camera(
        for shot: Storyboard.Shot,
        index: Int,
        take: AgentEditTake,
        analysis: TakeAnalysis,
        settings: ProjectEditSettings,
        autoZooms: [ZoomKeyframe]
    ) -> (keyframes: [ZoomKeyframe], description: String) {
        let shots = storyboard.shots
        let start = shot.span.start
        let end = shot.span.end
        let before = start - (index > 0 ? shots[index - 1].span.end : 0)
        let after = (index + 1 < shots.count ? shots[index + 1].span.start : take.duration) - end
        let preRoll = min(Self.roll, index > 0 ? before / 2 : before)
        let postRoll = min(Self.roll, index + 1 < shots.count ? after / 2 : after)
        let arrival = min(Self.arrival * shot.speed, shot.span.duration / 2)
        let crop = settings.cropMotion

        // Where to look: the shot's target, or its first click, or the middle.
        let target = shot.camera.target ?? actionPoint(in: shot.span, analysis: analysis).map {
            CGRect(x: $0.x, y: $0.y, width: 0, height: 0)
        }
        func aimed(_ keyframe: ZoomKeyframe, at rect: CGRect?, scale: CGFloat?) -> ZoomKeyframe {
            let base = crop.base(at: keyframe.peakTime)
            var result = keyframe
            if let scale {
                result.scale = scale
            }
            guard let rect else {
                return ZoomKeyframeEditor.keyframe(result, movingFocusTo: CGPoint(x: base.midX, y: base.midY), base: base)
            }
            if rect.width > 0, rect.height > 0, scale == nil {
                return ZoomKeyframeEditor.keyframe(result, focusingOn: rect, base: base)
            }
            return ZoomKeyframeEditor.keyframe(result, movingFocusTo: CGPoint(x: rect.midX, y: rect.midY), base: base)
        }
        func keyframe(_ from: TimeInterval, _ peak: TimeInterval, _ to: TimeInterval) -> ZoomKeyframe {
            ZoomKeyframe(startTime: from, peakTime: peak, endTime: to, center: .zero, scale: 1, source: .manual)
        }
        // A box sets how close by fitting it; a point (or nothing) takes the move's own.
        let boxed = (target?.width ?? 0) > 0
        func scale(_ fallback: CGFloat) -> CGFloat? {
            if let chosen = shot.camera.scale {
                return chosen
            }
            return boxed ? nil : fallback
        }

        switch shot.camera.move {
        case .hold:
            return ([], "hold")
        case .auto:
            let kept = autoZooms.filter { $0.peakTime >= start && $0.peakTime <= end }
            return (kept, "auto (\(kept.count) zoom\(kept.count == 1 ? "" : "s") onto clicks)")
        case .zoom:
            let made = aimed(keyframe(start, start + arrival, end + postRoll), at: target, scale: scale(settings.zoomPreset.settings.zoomScale))
            return ([made], String(format: "zoom %.1f×", Double(made.scale)))
        case .push:
            let made = aimed(keyframe(start, end, end + postRoll), at: target, scale: scale(Self.pushScale))
            return ([made], String(format: "push in to %.1f×", Double(made.scale)))
        case .pull:
            let hand = min(0.02, shot.span.duration / 10)
            let close = aimed(keyframe(start - preRoll, start, start + hand), at: target, scale: scale(Self.pullScale))
            let base = crop.base(at: end)
            let wide = ZoomKeyframe(
                startTime: start + hand,
                peakTime: end,
                endTime: end + postRoll,
                center: CGPoint(x: base.midX, y: base.midY),
                scale: 1,
                source: .manual
            )
            return ([close, wide], String(format: "pull back from %.1f×", Double(close.scale)))
        case .pan:
            let middle = start + shot.span.duration * 0.2
            let first = aimed(keyframe(start - preRoll, start, middle), at: target, scale: shot.camera.scale)
            var second = aimed(keyframe(middle, middle + shot.span.duration * 0.6, end + postRoll), at: shot.camera.to, scale: shot.camera.scale ?? first.scale)
            second.scale = first.scale
            return ([first, second], String(format: "pan at %.1f×", Double(first.scale)))
        }
    }

    /// Where the shot's first click group landed (normalized, bottom-left origin).
    func actionPoint(in span: TimeSpan, analysis: TakeAnalysis) -> CGPoint? {
        analysis.beats.first { $0.location != nil && $0.span.start >= span.start && $0.span.start <= span.end }?.location
    }

    // MARK: - Checks

    /// The hook, the rhythm of payoffs and the shots' lengths.
    func check(_ report: inout StoryboardReport, keyframes: [ZoomKeyframe], timeline: EditTimeline, analysis: TakeAnalysis) {
        let length = timeline.outputDuration
        let texts = report.shots.compactMap { $0.textOutput?.start }
        report.hookText = texts.min()
        var motion: [TimeInterval] = []
        for (shot, result) in zip(storyboard.shots, report.shots) where shot.camera.move != .hold || shot.camera.threeD != nil {
            motion.append(result.output.start)
        }
        let beats = analysis.beats.compactMap { timeline.outputTime(forSource: $0.span.start) }
        report.hookMotion = (motion + beats).min()
        if report.hookText == nil || report.hookText ?? 0 > Self.hookWindow {
            report.warnings.append("No text in the first \(Int(Self.hookWindow)) s: open with a title on the first shot (a hook).")
        }
        if (report.hookMotion ?? .infinity) > Self.hookWindow {
            report.warnings.append("Nothing moves in the first \(Int(Self.hookWindow)) s: give the first shot a push or zoom, or start on an action.")
        }
        if let first = report.shots.first, first.output.duration > 4 {
            report.warnings.append("The opening shot runs \(LaunchDemoRecipe.seconds(first.output.duration)); a hook works best under 3 s.")
        }

        // Something new lands: a cut, text, a zoom arriving, a result.
        var moments: [TimeInterval] = report.shots.dropFirst().map { $0.output.start } + texts
        moments += keyframes.compactMap { timeline.outputTime(forSource: $0.peakTime) }
        for (shot, result) in zip(storyboard.shots, report.shots) {
            if let payoff = shot.payoffAt, let time = timeline.outputTime(forSource: payoff) {
                moments.append(time)
            } else if shot.role == .payoff {
                moments.append(max(result.output.end - 0.4, result.output.start))
            }
        }
        report.payoffs = Array(Set(moments.map { ($0 * 100).rounded() / 100 }))
            .filter { $0 >= 0 && $0 <= length }
            .sorted()
        var longest: TimeSpan?
        var previous = 0.0
        for moment in report.payoffs + [length] {
            if moment - previous > (longest?.duration ?? 0) {
                longest = TimeSpan(start: previous, end: moment)
            }
            previous = moment
        }
        report.longestWait = longest
        if let longest, longest.duration > Self.longestWait {
            report.warnings.append(
                "Nothing new lands from \(LaunchDemoRecipe.seconds(longest.start)) to \(LaunchDemoRecipe.seconds(longest.end)) (\(LaunchDemoRecipe.seconds(longest.duration))): split that shot, speed it up, or land a caption or zoom there. Aim for a payoff every 3–5 s."
            )
        }
        for (index, shot) in report.shots.enumerated() {
            for warning in shot.warnings {
                report.warnings.append("shots[\(index)]: \(warning)")
            }
        }
    }
}

extension StoryboardReport {
    /// The report as agents read it: output seconds unless said otherwise.
    var json: JSONValue {
        var value: [String: JSONValue] = [:]
        value["changes"] = .array(changes.map { JSONValue.string($0) })
        value["output_duration"] = AgentTime.json(outputDuration)
        value["shots"] = .array(shots.enumerated().map { index, shot -> JSONValue in
            var entry: [String: JSONValue] = [
                "index": .number(Double(index)),
                "role": .string(shot.role.rawValue),
                "source_start": AgentTime.json(shot.source.start),
                "source_end": AgentTime.json(shot.source.end),
                "output_start": AgentTime.json(shot.output.start),
                "output_end": AgentTime.json(shot.output.end),
                "speed": .number(shot.speed),
                "camera": .string(shot.camera)
            ]
            if let id = shot.textID, let text = shot.textOutput {
                entry["text_id"] = .string(id.uuidString)
                entry["text_output_start"] = AgentTime.json(text.start)
                entry["text_output_end"] = AgentTime.json(text.end)
            }
            if !shot.warnings.isEmpty {
                entry["warnings"] = .array(shot.warnings.map { JSONValue.string($0) })
            }
            return .object(entry)
        })
        value["hook"] = [
            "ok": .bool(hookOK),
            "text_at": hookText.map { AgentTime.json($0) } ?? JSONValue.null,
            "motion_at": hookMotion.map { AgentTime.json($0) } ?? JSONValue.null
        ]
        value["payoffs_output"] = .array(payoffs.map { AgentTime.json($0) })
        if let longestWait {
            value["longest_wait"] = TakeAnalysis.json(longestWait)
        }
        value["warnings"] = .array(warnings.map { JSONValue.string($0) })
        value["suggestions"] = .array(suggestions.map { JSONValue.string($0) })
        return .object(value)
    }
}
