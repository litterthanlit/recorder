import CoreGraphics
import Foundation

/// How tightly a launch demo is cut, and how hard it moves.
enum LaunchDemoPace: String, CaseIterable {
    /// Room to breathe: only long pauses go, waits play at 2–4×, gentle zooms.
    case relaxed
    /// Pauses over 1.5 s go, waits play at 4–8×.
    case snappy
    /// Every pause goes, waits play at 6–12×, punchy zooms.
    case punchy

    /// Dead air at least this long is cut; shorter pauses stay as breathing room.
    var minimumDead: TimeInterval {
        switch self {
        case .relaxed: return 2.5
        case .snappy: return 1.5
        case .punchy: return 1.2
        }
    }

    /// How fast waits (only the screen moving) play.
    var waitSpeeds: ClosedRange<Double> {
        switch self {
        case .relaxed: return 2...4
        case .snappy: return 4...8
        case .punchy: return 6...12
        }
    }

    var zoomPreset: ZoomPreset {
        switch self {
        case .relaxed: return .subtle
        case .snappy: return .demo
        case .punchy: return .punch
        }
    }

    /// How long a transition at a cut lasts.
    var transitionDuration: TimeInterval {
        switch self {
        case .relaxed: return 0.5
        case .snappy: return 0.4
        case .punchy: return 0.3
        }
    }
}

/// A caption for a launch demo, at a moment of the recording (source seconds) or, without
/// one, wherever it fits.
struct LaunchDemoCaption: Equatable {
    var text: String
    var at: TimeInterval?
}

/// What a launch demo says and how it looks.
struct LaunchDemoOptions: Equatable {
    var title: String?
    var tagline: String?
    var captions: [LaunchDemoCaption] = []
    /// The app the demo is about: the video is cropped to its window.
    var app: String?
    /// A look's name; `nil` keeps the take's look.
    var look: String?
    var aspect: OutputAspect?
    /// Fill a shape other than the picture's by following the action; `nil` reframes
    /// when `aspect` is given and leaves the take's choice otherwise.
    var reframe: Bool?
    var pace: LaunchDemoPace = .snappy
    /// At every cut; `nil` for straight cuts.
    var transition: CutTransitionStyle? = .zoomBlur
    /// How all the text comes on; `nil` lets the title rise and captions pop.
    var textAnimation: TextAnimation?
    var tiltIn = true
    var cropToApp = true
}

extension LaunchDemoOptions {
    static let maximumCaptions = 20

    /// make_launch_demo's arguments.
    init(_ arguments: AgentArguments) throws {
        self.init()
        title = try Self.trimmed(arguments, "title")
        tagline = try Self.trimmed(arguments, "tagline")
        captions = try Self.parseCaptions(arguments)
        app = try Self.trimmed(arguments, "app")
        look = try Self.trimmed(arguments, "look")
        if let shape = try arguments.string("aspect") {
            guard let parsed = AgentAspect.parse(shape) else {
                throw AgentToolError("aspect must be one of \(AgentAspect.choices) (got \"\(shape)\").")
            }
            aspect = parsed
        }
        reframe = try arguments.bool("reframe")
        pace = try arguments.choice("pace", LaunchDemoPace.self) ?? .snappy
        if let name = try arguments.string("transition") {
            switch AgentEdits.parseTransition(name) {
            case let .style(style)?:
                transition = style
            case .straight?:
                transition = nil
            case nil:
                throw AgentToolError("transition must be zoom_blur, whip, blur_dip or none (got \"\(name)\").")
            }
        }
        textAnimation = try arguments.choice("text_animation", TextAnimation.self)
        tiltIn = try arguments.bool("tilt_in") ?? true
        cropToApp = try arguments.bool("crop_to_app") ?? true
    }

    /// The text at `key` without surrounding spaces; `nil` when missing or empty.
    private static func trimmed(_ arguments: AgentArguments, _ key: String) throws -> String? {
        let value = try arguments.string(key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    /// `captions`: text, or `{text, at}` with `at` in source seconds.
    private static func parseCaptions(_ arguments: AgentArguments) throws -> [LaunchDemoCaption] {
        guard let list = try arguments.array("captions") else { return [] }
        guard list.count <= maximumCaptions else {
            throw AgentToolError("At most \(maximumCaptions) captions; a launch demo reads better with a few short ones.")
        }
        var result: [LaunchDemoCaption] = []
        for (index, value) in list.enumerated() {
            if let line = value.stringValue {
                let words = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !words.isEmpty {
                    result.append(LaunchDemoCaption(text: words, at: nil))
                }
                continue
            }
            guard let object = value.objectValue else {
                throw AgentToolError("captions[\(index)] must be text, or {text, at}.")
            }
            do {
                let caption = AgentArguments(values: object)
                let words = try caption.requiredString("text").trimmingCharacters(in: .whitespacesAndNewlines)
                result.append(LaunchDemoCaption(text: words, at: try caption.time("at")))
            } catch let error as AgentToolError {
                throw AgentToolError("captions[\(index)]: \(error.message)")
            }
        }
        return result
    }
}

/// What make_launch_demo did.
struct LaunchDemoReport: Equatable {
    /// A piece of text the recipe added, with where it shows in the finished video.
    struct PlacedText: Equatable {
        enum Role: String {
            case title, tagline, caption
        }

        var role: Role
        var id: UUID
        var text: String
        /// Output seconds.
        var output: TimeSpan
    }

    /// What changed, in words.
    var changes: [String] = []
    /// What the recipe couldn't do, and how to finish it with the other tools.
    var suggestions: [String] = []
    /// Source time cut inside the kept range: pauses, detours and other apps covering
    /// the app.
    var cuts: [TimeSpan] = []
    var speedUps: [TakeAnalysis.SpeedUp] = []
    /// The app the video is cropped to.
    var croppedTo: String?
    /// Whether the crop follows the app's window as it moves.
    var cropFollows = false
    /// Other apps' windows over the app's, and what was done about each.
    var covers: [TakeAnalysis.Cover] = []
    /// The blur boxes hiding them.
    var coverBlurs: [UUID] = []
    var outputDuration: TimeInterval = 0
    var text: [PlacedText] = []
    /// Captions there wasn't room for.
    var leftOut: [String] = []
    /// Where the beats (clicks, typing, shortcuts) land in the finished video, for timing
    /// captions.
    var beats: [TimeInterval] = []
}

/// Turns a take into a launch demo in one go, from its analysis. In order:
///
/// 1. Trims the lead-in and tail.
/// 2. Cuts pauses (as long as the pace allows), detours to other apps and other apps'
///    windows hiding much of the app's, never speech.
/// 3. Speeds through waits, easing in and out of them.
/// 4. Crops to the app's window, following it as it moves, when the take knows where it
///    was, and blurs smaller windows of other apps lying over it.
/// 5. Remakes the auto zooms with the pace's feel (manual zooms stay).
/// 6. Applies the look and shape, motion blur and the spring camera.
/// 7. Opens with a 3D tilt-in, with transitions and audio fades at cuts.
/// 8. Adds the title, tagline and captions, each up long enough to read.
///
/// It rebuilds the timeline from the whole recording and rewrites the text when given
/// some; blur boxes, manual zooms and other 3D moves stay.
struct LaunchDemoRecipe {
    var options: LaunchDemoOptions
    /// Cuts keep this much either side of a pause and are at least `minimumCut` long,
    /// like the analysis's own.
    var cutMargin: TimeInterval = TakeAnalyzer().cutMargin
    var minimumCut: TimeInterval = TakeAnalyzer().minimumCut

    /// The title comes on this far into the video, as the tilt-in gets going…
    static let titleDelay: TimeInterval = 0.3
    /// …and the tagline this long after it.
    static let taglineDelay: TimeInterval = 0.4
    static let titleCenter = CGPoint(x: 0.5, y: 0.42)
    static let titleCenterAboveTagline = CGPoint(x: 0.5, y: 0.38)
    static let taglineCenter = CGPoint(x: 0.5, y: 0.53)
    static let captionCenter = CGPoint(x: 0.5, y: 0.84)
    /// Between one piece of text and the next.
    static let textGap: TimeInterval = 0.2
    /// Captions that can't stay up this long are left out.
    static let minimumCaption: TimeInterval = 1.2
    /// Text isn't left on the last moments of the video.
    static let endMargin: TimeInterval = 0.3

    /// Long enough to read: 0.4 s plus 0.07 s a character, between 2 and 4.5 s.
    static func holdDuration(_ text: String) -> TimeInterval {
        min(max(0.4 + 0.07 * Double(text.count), 2), 4.5)
    }

    func apply(to snapshot: inout EditorSnapshot, take: AgentEditTake, analysis: TakeAnalysis) throws -> LaunchDemoReport {
        var report = LaunchDemoReport()
        var settings = snapshot.editSettings
        let pace = options.pace

        // The look first: it sets the canvas and background the rest builds on.
        if let name = options.look {
            let look = try AgentEdits.look(named: name, in: take.looks)
            look.apply(to: &settings)
            report.changes.append("Applied the \(look.name) look.")
        }
        if let aspect = options.aspect {
            settings.canvas.aspect = aspect
            settings.canvas.reframes = options.reframe ?? true
            report.changes.append("Shape \(AgentAspect.name(aspect)).")
        } else if let reframe = options.reframe {
            settings.canvas.reframes = reframe
        }

        let timeline = makeTimeline(take: take, analysis: analysis, report: &report)
        settings.setTimeline(timeline)
        cropToApp(&settings, take: take, analysis: analysis, report: &report)
        hideCovers(&settings, analysis: analysis, report: &report)

        settings.zoomPreset = pace.zoomPreset
        let keyframes = ZoomKeyframeEditor.replacingAutoZooms(
            in: snapshot.keyframes,
            clicks: take.clicks,
            preset: pace.zoomPreset,
            frameSize: take.sourceSize
        )
        let autoZooms = keyframes.filter { $0.source == .auto }.count
        report.changes.append("\(autoZooms) zoom\(autoZooms == 1 ? "" : "s") onto clicks (\(pace.zoomPreset.label.lowercased()) feel); manual zooms kept.")

        settings.exportStyle.motionBlurEnabled = true
        settings.exportStyle.springCameraEnabled = true
        settings.audio.cutFades = true
        settings.audio.muteSpedUp = true
        if let style = options.transition {
            settings.cutTransition = CutTransition(style: style, duration: pace.transitionDuration)
            report.changes.append("\(style.label) transitions at cuts, audio fades, silent sped-up parts, motion blur and a spring camera.")
        } else {
            settings.cutTransition = nil
            report.changes.append("Straight cuts with audio fades, silent sped-up parts, motion blur and a spring camera.")
        }

        if settings.canvas.reframes {
            settings.reframe = Reframer.reframe(settings, keyframes: keyframes, take: take)
            if settings.reframe != nil {
                report.changes.append("Reframed for \(AgentAspect.name(settings.canvas.aspect)): the frame follows the clicks, typing and zooms.")
            }
        }
        addTiltIn(&settings, timeline: timeline, take: take, report: &report)
        report.beats = Self.beatTimes(analysis.beats, in: timeline)
        addText(&settings, timeline: timeline, report: &report)

        snapshot.keyframes = keyframes
        snapshot.editSettings = settings
        report.outputDuration = timeline.outputDuration
        return report
    }

    // MARK: - Steps

    /// Steps 1–3: the whole recording, trimmed, with pauses and detours cut and waits sped
    /// through, easing in and out of speed changes.
    func makeTimeline(take: AgentEditTake, analysis: TakeAnalysis, report: inout LaunchDemoReport) -> EditTimeline {
        let duration = take.duration
        var timeline = EditTimeline(sourceDuration: duration)
        timeline.speedRamp = SpeedRamp.defaultRamp

        let kept = analysis.kept
        var trimmed: [String] = []
        if kept.start > 0, timeline.excludeSource(TimeSpan(start: 0, end: kept.start)) {
            trimmed.append("the lead-in (\(Self.seconds(kept.start)))")
        }
        if kept.end < duration, timeline.excludeSource(TimeSpan(start: kept.end, end: duration)) {
            trimmed.append("the tail (\(Self.seconds(duration - kept.end)))")
        }
        if !trimmed.isEmpty {
            report.changes.append("Trimmed \(trimmed.joined(separator: " and ")).")
        }

        let pauses: [TimeSpan] = analysis.dead.compactMap { span in
            guard span.duration >= options.pace.minimumDead - 1e-9 else { return nil }
            let cut = TimeSpan(start: span.start + cutMargin, end: span.end - cutMargin)
            return cut.duration >= minimumCut - 1e-9 ? cut : nil
        }
        let covered = analysis.covers.filter { $0.action == .cut }.flatMap { cover in cover.pieces.map { $0.span } }
        var pauseCount = 0
        var pauseTime: TimeInterval = 0
        var detourCount = 0
        var detourTime: TimeInterval = 0
        var coverCount = 0
        var coverTime: TimeInterval = 0
        for cut in AgentEdits.merged(pauses + analysis.offApp + covered) where cut.duration > 0 {
            guard timeline.excludeSource(cut) else { continue }
            report.cuts.append(cut)
            if analysis.offApp.contains(where: { $0.intersection(cut) != nil }) {
                detourCount += 1
                detourTime += cut.duration
            } else if covered.contains(where: { $0.intersection(cut) != nil }) {
                coverCount += 1
                coverTime += cut.duration
            } else {
                pauseCount += 1
                pauseTime += cut.duration
            }
        }
        var cutParts: [String] = []
        if pauseCount > 0 {
            cutParts.append("\(pauseCount) pause\(pauseCount == 1 ? "" : "s") (\(Self.seconds(pauseTime)))")
        }
        if detourCount > 0 {
            cutParts.append("\(detourCount) detour\(detourCount == 1 ? "" : "s") to other apps (\(Self.seconds(detourTime)))")
        }
        if coverCount > 0 {
            cutParts.append("\(coverCount) moment\(coverCount == 1 ? "" : "s") another app hid much of the window (\(Self.seconds(coverTime)))")
        }
        if !cutParts.isEmpty {
            let list = cutParts.count > 1
                ? cutParts.dropLast().joined(separator: ", ") + " and " + (cutParts.last ?? "")
                : cutParts[0]
            report.changes.append("Cut \(list).")
        }

        let speeds = options.pace.waitSpeeds
        for wait in analysis.speedUps {
            let speed = min(max(wait.speed, speeds.lowerBound), speeds.upperBound)
            timeline.applySpeed(speed, toSource: wait.span)
            report.speedUps.append(TakeAnalysis.SpeedUp(span: wait.span, speed: speed))
        }
        if !report.speedUps.isEmpty {
            let count = report.speedUps.count
            let fastest = report.speedUps.map { $0.speed }.max() ?? speeds.lowerBound
            let slowest = report.speedUps.map { $0.speed }.min() ?? speeds.lowerBound
            let rate = fastest == slowest ? Timecode.speed(fastest) : "\(Timecode.speed(slowest))–\(Timecode.speed(fastest))"
            report.changes.append("Sped through \(count) wait\(count == 1 ? "" : "s") at \(rate), easing in and out.")
        }

        let result = timeline.normalized(sourceDuration: duration)
        report.changes.insert(
            "Rebuilt the edit from the whole recording: \(Self.seconds(duration)) → \(Self.seconds(result.outputDuration)).",
            at: 0
        )
        return result
    }

    /// Step 4: crop to the app's window, following it as it moves, when the take
    /// recorded where it was.
    func cropToApp(
        _ settings: inout ProjectEditSettings,
        take: AgentEditTake,
        analysis: TakeAnalysis,
        report: inout LaunchDemoReport
    ) {
        guard options.cropToApp else { return }
        guard !take.appFocus.isEmpty else {
            report.suggestions.append(
                "This take doesn't record which app was in front, so it isn't cropped. To show only the app, find its window with view_frames (grid true) and call set_crop with its rect."
            )
            return
        }
        guard let app = options.app ?? analysis.focusApp else { return }
        let name = take.appFocus.first(where: { $0.isApp(app) })?.appName ?? app
        guard let window = WindowCrop.following(app, in: take.appFocus, duration: take.duration) else {
            report.suggestions.append(
                "\(name)'s window never showed in the recording, so it isn't cropped. Crop with set_crop rect if other apps show."
            )
            return
        }
        guard let crop = window.crop else {
            report.changes.append("\(name)'s window fills the recording, so it isn't cropped.")
            return
        }
        settings.sourceCrop = crop
        settings.cropPath = window.path
        report.croppedTo = name
        report.cropFollows = window.path != nil
        let pixels = SourceCrop.contentSize(source: take.sourceSize, crop: crop)
        let size = "\(Int(pixels.width.rounded()))×\(Int(pixels.height.rounded())) px"
        if window.path != nil {
            let moves = window.moves == 1 ? "once" : "\(window.moves) times"
            report.changes.append("Cropped to \(name)'s window (\(size)), following it as it moves (it moved \(moves)).")
        } else {
            report.changes.append("Cropped to \(name)'s window (\(size)).")
        }
    }

    /// Step 4, too: blur other apps' windows over the app's where they're left in (big
    /// ones were cut with the timeline), and say which were left because of talking.
    func hideCovers(_ settings: inout ProjectEditSettings, analysis: TakeAnalysis, report: inout LaunchDemoReport) {
        report.covers = analysis.covers
        guard !analysis.covers.isEmpty, let app = analysis.focusApp else { return }
        var blurred: [String] = []
        for cover in analysis.covers where cover.action == .blur {
            for piece in cover.pieces {
                // A box from an earlier run stays as it is.
                if let same = settings.blurRegions.first(where: { $0.span == piece.span && Self.sameRect($0.rect, piece.rect) }) {
                    report.coverBlurs.append(same.id)
                    continue
                }
                let region = BlurRegion(span: piece.span, rect: piece.rect, kind: .blur, strength: TakeAnalysis.coverBlurStrength)
                settings.blurRegions.append(region)
                report.coverBlurs.append(region.id)
            }
            blurred.append("\(cover.appName) (\(Self.seconds(cover.span.duration)))")
        }
        if !blurred.isEmpty {
            report.changes.append("Blurred other apps' windows over \(app): \(blurred.joined(separator: ", ")).")
        }
        for cover in analysis.covers where cover.action == .keep {
            report.suggestions.append(
                "\(cover.appName) was in front of \(app) for \(Self.seconds(cover.span.duration)) at \(Self.seconds(cover.span.start)) while you were talking, so it stays. If it shouldn't show, cut it with edit_timeline or hide it with edit_blur."
            )
        }
    }

    private static func sameRect(_ first: CGRect, _ second: CGRect) -> Bool {
        abs(first.minX - second.minX) < 1e-6 && abs(first.minY - second.minY) < 1e-6
            && abs(first.width - second.width) < 1e-6 && abs(first.height - second.height) < 1e-6
    }

    /// Step 7: tilt in over the first moments of the video, in its first segment.
    func addTiltIn(
        _ settings: inout ProjectEditSettings,
        timeline: EditTimeline,
        take: AgentEditTake,
        report: inout LaunchDemoReport
    ) {
        guard options.tiltIn else { return }
        guard settings.exportStyle.background.kind != BackgroundKind.none else {
            report.suggestions.append(
                "No 3D tilt-in: the look has no background, so the recording fills the frame. Pick a look with one (set_style look), then add it with edit_camera_moves."
            )
            return
        }
        guard let first = timeline.segments.first else { return }
        // One opening: a tilt in from an earlier run goes.
        settings.cameraMoves.removeAll { $0.kind == .tiltIn }
        let length = CameraMoveKind.tiltIn.defaultDuration
        let start = first.source.start
        var end = min(start + length * first.speed, first.source.end)
        if end - start < length / 2 {
            // A very short first segment: let the move run on in source time.
            end = min(start + length, take.duration)
        }
        settings.cameraMoves.append(CameraMove(kind: .tiltIn, span: TimeSpan(start: start, end: end)))
        report.changes.append("Opens with a 3D tilt-in.")
    }

    /// Step 8: the title and tagline as it opens, then the captions, replacing the text.
    func addText(_ settings: inout ProjectEditSettings, timeline: EditTimeline, report: inout LaunchDemoReport) {
        guard options.title != nil || options.tagline != nil || !options.captions.isEmpty else {
            report.suggestions.append(
                "No title or captions were given. Add them with edit_text (time_base \"output\"); beats lists where the actions land."
            )
            return
        }
        settings.textOverlays.removeAll()
        let length = timeline.outputDuration
        let latest = max(length - Self.endMargin, 0)

        func add(_ role: LaunchDemoReport.PlacedText.Role, _ text: String, _ output: TimeSpan, style: TextOverlay.Style, center: CGPoint, animation: TextAnimation) {
            let span = TimeSpan(start: timeline.sourceTime(forOutput: output.start), end: timeline.sourceTime(forOutput: output.end))
            let overlay = TextOverlay(text: text, span: span, center: center, style: style, animation: animation)
            settings.textOverlays.append(overlay)
            report.text.append(LaunchDemoReport.PlacedText(role: role, id: overlay.id, text: text, output: output))
        }

        // The opening: the title, the tagline just after it, leaving together.
        let opening = options.textAnimation ?? .rise
        let titleStart = min(Self.titleDelay, length * 0.1)
        let taglineStart = options.title == nil ? titleStart : titleStart + Self.taglineDelay
        var openingEnd = titleStart
        if let title = options.title {
            openingEnd = max(openingEnd, titleStart + Self.holdDuration(title))
        }
        if let tagline = options.tagline {
            openingEnd = max(openingEnd, taglineStart + Self.holdDuration(tagline))
        }
        openingEnd = min(openingEnd, latest)
        if let title = options.title {
            if openingEnd - titleStart >= Self.minimumCaption - 1e-9 {
                let center = options.tagline == nil ? Self.titleCenter : Self.titleCenterAboveTagline
                add(.title, title, TimeSpan(start: titleStart, end: openingEnd), style: .title, center: center, animation: opening)
            } else {
                report.leftOut.append(title)
            }
        }
        if let tagline = options.tagline {
            if openingEnd - taglineStart >= Self.minimumCaption - 1e-9 {
                add(.tagline, tagline, TimeSpan(start: taglineStart, end: openingEnd), style: .caption, center: Self.taglineCenter, animation: opening)
            } else {
                report.leftOut.append(tagline)
            }
        }

        // Then the captions, in the rest of the video.
        let window = TimeSpan(start: report.text.isEmpty ? 0 : openingEnd + Self.textGap, end: latest)
        let spans = Self.captionSpans(
            options.captions,
            window: window,
            beats: report.beats,
            outputTime: { timeline.outputTimeClamped(forSource: $0) }
        )
        let animation = options.textAnimation ?? .pop
        for (caption, span) in zip(options.captions, spans) {
            if let span {
                add(.caption, caption.text, span, style: .caption, center: Self.captionCenter, animation: animation)
            } else {
                report.leftOut.append(caption.text)
            }
        }
        report.text.sort { $0.output.start < $1.output.start }

        var parts: [String] = []
        if let title = report.text.first(where: { $0.role == .title }) {
            parts.append("the title \"\(AgentEdits.shortened(title.text))\"")
        }
        if report.text.contains(where: { $0.role == .tagline }) {
            parts.append("a tagline")
        }
        let captions = report.text.filter { $0.role == .caption }.count
        if captions > 0 {
            parts.append("\(captions) caption\(captions == 1 ? "" : "s")")
        }
        if !parts.isEmpty {
            report.changes.append("Text: \(parts.joined(separator: ", ")), replacing what was there.")
        }
        if !report.leftOut.isEmpty {
            report.suggestions.append(
                "\(report.leftOut.count) piece\(report.leftOut.count == 1 ? "" : "s") of text didn't fit the video; shorten them or use fewer (left_out)."
            )
        }
    }

    // MARK: - Placing text

    /// Where captions go, in output seconds: at their `at` when given, otherwise spread
    /// evenly over `window` in order, each moved onto the first beat in its share that
    /// leaves it room, so it lands with an action. Captions never overlap (an earlier one
    /// keeps its place, a later one waits) and stay inside `window`; one that can't stay
    /// up `minimumCaption` is left out (`nil`).
    static func captionSpans(
        _ captions: [LaunchDemoCaption],
        window: TimeSpan,
        beats: [TimeInterval],
        outputTime: (TimeInterval) -> TimeInterval
    ) -> [TimeSpan?] {
        var spans = [TimeSpan?](repeating: nil, count: captions.count)
        guard !captions.isEmpty, window.duration > 0 else { return spans }
        let share = window.duration / Double(captions.count)
        var starts: [TimeInterval] = []
        for (index, caption) in captions.enumerated() {
            if let at = caption.at {
                starts.append(outputTime(at))
                continue
            }
            let shareStart = window.start + Double(index) * share
            let latest = shareStart + share - holdDuration(caption.text)
            let beat = beats.first { $0 >= shareStart && $0 <= latest }
            starts.append(beat ?? shareStart)
        }

        let order = starts.indices.sorted { starts[$0] != starts[$1] ? starts[$0] < starts[$1] : $0 < $1 }
        var previousEnd = -Double.infinity
        for index in order {
            let start = max(starts[index], window.start, previousEnd + textGap)
            let end = min(start + holdDuration(captions[index].text), window.end)
            guard end - start >= minimumCaption - 1e-9 else { continue }
            spans[index] = TimeSpan(start: start, end: end)
            previousEnd = end
        }
        return spans
    }

    /// Where `beats` land in `timeline`, in output seconds, a second or more apart.
    static func beatTimes(_ beats: [TakeAnalysis.Beat], in timeline: EditTimeline) -> [TimeInterval] {
        var result: [TimeInterval] = []
        for time in beats.compactMap({ timeline.outputTime(forSource: $0.span.start) }).sorted() {
            if let last = result.last, time - last < 1 {
                continue
            }
            result.append(time)
        }
        return result
    }

    static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.1f s", value)
    }
}

extension LaunchDemoReport {
    /// The report as agents read it: source seconds for cuts, output seconds for text.
    var json: JSONValue {
        var value: [String: JSONValue] = [:]
        value["changes"] = .array(changes.map { JSONValue.string($0) })
        value["output_duration"] = AgentTime.json(outputDuration)
        value["cuts"] = .array(cuts.map { TakeAnalysis.json($0) })
        value["speed_ups"] = .array(speedUps.map { wait -> JSONValue in
            [
                "start": AgentTime.json(wait.span.start),
                "end": AgentTime.json(wait.span.end),
                "speed": .number(wait.speed)
            ]
        })
        value["cropped_to"] = croppedTo.map { JSONValue.string($0) } ?? JSONValue.null
        if croppedTo != nil {
            value["crop_follows_window"] = .bool(cropFollows)
        }
        if !covers.isEmpty {
            value["covers"] = .array(covers.map { cover -> JSONValue in
                [
                    "app": .string(cover.appName),
                    "start": AgentTime.json(cover.span.start),
                    "end": AgentTime.json(cover.span.end),
                    "action": .string(cover.action.rawValue)
                ]
            })
            value["cover_blur_ids"] = .array(coverBlurs.map { JSONValue.string($0.uuidString) })
        }
        value["text"] = .array(text.map { placed -> JSONValue in
            [
                "role": .string(placed.role.rawValue),
                "text_id": .string(placed.id.uuidString),
                "text": .string(placed.text),
                "output_start": AgentTime.json(placed.output.start),
                "output_end": AgentTime.json(placed.output.end)
            ]
        })
        value["beats_output"] = .array(beats.map { AgentTime.json($0) })
        if !leftOut.isEmpty {
            value["left_out"] = .array(leftOut.map { JSONValue.string($0) })
        }
        value["suggestions"] = .array(suggestions.map { JSONValue.string($0) })
        return .object(value)
    }
}
