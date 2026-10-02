import CoreGraphics
import Foundation

/// What reading a take's files found (the app reads them; this is only the result).
struct TakeMediaScan: Equatable {
    /// When the recording has a frame, which is when the screen changed. Sorted.
    var frameTimes: [TimeInterval]
    /// How much of the screen changed, a few times a second where it did; `nil` when no
    /// thumbnails could be made.
    var screen: [VisualChangeSample]?
    /// Speech on the microphone; `nil` when the take has no microphone track.
    var speech: [TimeSpan]?
}

/// Everything the analyzer looks at, in source time.
struct TakeAnalysisInput {
    var duration: TimeInterval
    /// The recording's size in pixels.
    var frameSize: CGSize
    var clicks: [ClickEvent]
    var keystrokes: [KeystrokeEvent]
    var cursor: [CursorEvent]
    /// `nil` when the screen wasn't scanned.
    var screen: [VisualChangeSample]?
    /// `nil` without a microphone.
    var speech: [TimeSpan]?
    /// Which app was in front; `nil` for takes from before Trace kept it.
    var focus: [AppFocusEvent]? = nil
    /// The app the demo is about; the one in front the longest when `nil`.
    var focusApp: String? = nil
}

/// A take's activity: where the demo really starts and ends, the dead air and the waits
/// in between, and an edit that takes them out. All in source time.
struct TakeAnalysis: Equatable {
    struct Beat: Equatable {
        enum Kind: String {
            case clicks
            case typing
            case shortcut
        }

        var kind: Kind
        var span: TimeSpan
        var count: Int
        /// Where clicks landed: normalized, bottom-left origin.
        var location: CGPoint?
    }

    struct SpeedUp: Equatable {
        var span: TimeSpan
        var speed: Double
    }

    struct AppShare: Equatable {
        var appName: String
        var seconds: TimeInterval
    }

    /// Another app's window over the product's window in the kept part of a take: a
    /// floating window, a menu bar extra's menu, a notification, the Dock, or another app
    /// brought in front while talking.
    struct Cover: Equatable {
        enum Action: String {
            /// It hides much of the window and nobody's talking: cut.
            case cut
            /// Blurred where it lies over the window.
            case blur
            /// Another app brought in front while talking (a detour being explained):
            /// left in.
            case keep
        }

        /// Where it lay over the window for a stretch.
        struct Piece: Equatable {
            var span: TimeSpan
            /// Normalized, bottom-left origin, inside the window (with a little room for
            /// its shadow).
            var rect: CGRect
            /// How much of the window it hid (0–1).
            var share: Double
        }

        var appName: String
        /// From the first piece to the last.
        var span: TimeSpan
        var pieces: [Piece]
        var action: Action

        /// The most of the window it hid at once.
        var share: Double {
            pieces.map { $0.share }.max() ?? 0
        }
    }

    var duration: TimeInterval
    /// Before the first action: waiting after the countdown, reaching for the app.
    var leadIn: TimeSpan?
    /// After the last action: reaching for the stop button.
    var tail: TimeSpan?
    /// Nothing happens: no input, no speech, a still screen.
    var dead: [TimeSpan]
    /// Only the screen moves: something loading or playing out.
    var quiet: [TimeSpan]
    /// Another app in front of the one the demo is about (a detour), as cut.
    var offApp: [TimeSpan] = []
    /// Other apps' windows over the app's window where it's kept, with what to do.
    var covers: [Cover] = []
    /// The app the demo is about, when the take knows which apps were in front.
    var focusApp: String?
    /// How long each app was in front, most first.
    var apps: [AppShare] = []
    var speech: [TimeSpan]?
    /// Where the screen changes; `nil` when it wasn't scanned.
    var screenActivity: [TimeSpan]?
    var beats: [Beat]
    /// The demo itself: the take without its lead-in and tail.
    var kept: TimeSpan
    /// Dead air, detours and big covers to cut, inside `kept`.
    var cuts: [TimeSpan]
    /// Waits to speed through, inside `kept`.
    var speedUps: [SpeedUp]

    /// The suggested edit: trimmed to `kept`, with the cuts and speed-ups.
    func suggestedTimeline() -> EditTimeline {
        var timeline = EditTimeline(sourceDuration: duration)
        if kept.start > 0 {
            timeline.excludeSource(TimeSpan(start: 0, end: kept.start))
        }
        if kept.end < duration {
            timeline.excludeSource(TimeSpan(start: kept.end, end: duration))
        }
        for cut in cuts {
            timeline.excludeSource(cut)
        }
        for speedUp in speedUps {
            timeline.applySpeed(speedUp.speed, toSource: speedUp.span)
        }
        return timeline.normalized(sourceDuration: duration)
    }
}

/// Finds a take's lead-in, tail, dead air and waits from what was recorded: clicks, keys,
/// pointer movement (jitter doesn't count), speech and screen changes, looked at on a
/// 0.1 s grid.
struct TakeAnalyzer {
    var step: TimeInterval = 0.1
    /// Stillness at least this long is dead air…
    var minimumDead: TimeInterval = 1.2
    /// …and a moving screen with nobody acting this long is a wait.
    var minimumQuiet: TimeInterval = 1.2
    /// Kept around a click (before, after): the reach for it and its effect.
    var clickBefore: TimeInterval = 0.3
    var clickAfter: TimeInterval = 0.6
    var keyBefore: TimeInterval = 0.2
    var keyAfter: TimeInterval = 0.4
    var speechPadding: TimeInterval = 0.15
    /// The pointer moving more than this fraction of the frame's diagonal in one step is
    /// activity (about 7 px at 1080p).
    var cursorThreshold: Double = 0.003
    /// Clicks and keys this close to the end are stopping the recording.
    var stopGesture: TimeInterval = 0.6
    /// The demo starts this long before the first action…
    var leadInMargin: TimeInterval = 0.5
    /// …and holds this long after the last, longer while the screen settles (up to
    /// `maximumSettle`).
    var tailHold: TimeInterval = 0.8
    var maximumSettle: TimeInterval = 3
    /// Lead-ins and tails shorter than this are left alone.
    var minimumEdge: TimeInterval = 0.5
    /// Cuts keep this much either side of dead air, and are at least `minimumCut` long.
    var cutMargin: TimeInterval = 0.2
    var minimumCut: TimeInterval = 1
    /// Waits at least `minimumSpeedUp` long are sped up to last about `quietTarget`
    /// (2–8×).
    var minimumSpeedUp: TimeInterval = 1.5
    var quietTarget: TimeInterval = 0.8
    /// A detour's cut reaches this far past the other app's time in front on each side,
    /// so none of it shows (app switches are noted as they happen)…
    var detourPadding: TimeInterval = 0.05
    /// …and shorter detours are left.
    var minimumDetour: TimeInterval = 0.1
    /// A window over the app's is cut when it hides at least this much of it (with
    /// nobody talking), blurred otherwise…
    var bigCover = 0.25
    /// …and ignored when it hides less than this (a sliver along an edge).
    var minimumCover = 0.002
    /// Covers are looked for four times a second, so one may have come up this long
    /// before it was seen.
    var coverLag: TimeInterval = 0.25
    /// A blur box reaches this far (of the recording) past the window it hides, for its
    /// shadow.
    var coverPadding: CGFloat = 0.006
    /// Sightings of one app this close together are one cover.
    var coverJoin: TimeInterval = 0.3

    func analyze(_ input: TakeAnalysisInput) -> TakeAnalysis {
        let duration = max(input.duration, 0)
        let count = max(1, Int((duration / step - 1e-9).rounded(.up)))
        let stopTime = duration - stopGesture
        let clicks = input.clicks.filter { $0.timestamp < stopTime }.sorted { $0.timestamp < $1.timestamp }
        let keys = input.keystrokes.filter { $0.timestamp < stopTime }.sorted { $0.timestamp < $1.timestamp }
        let speech = input.speech?.sorted { $0.start < $1.start }
        let screenSpans = input.screen.map { VisualChange.movingSpans($0) }

        var active = [Bool](repeating: false, count: count)
        var moving = [Bool](repeating: false, count: count)
        for click in clicks {
            mark(&active, from: click.timestamp - clickBefore, to: click.timestamp + clickAfter)
        }
        for key in keys {
            mark(&active, from: key.timestamp - keyBefore, to: key.timestamp + keyAfter)
        }
        for span in speech ?? [] {
            mark(&active, from: span.start - speechPadding, to: span.end + speechPadding)
        }
        markCursor(input.cursor, frameSize: input.frameSize, in: &active)
        for span in screenSpans ?? [] {
            mark(&moving, from: span.start, to: span.end)
        }

        let kept = keptRange(duration: duration, clicks: clicks, keys: keys, speech: speech, screen: screenSpans ?? [])
        var dead: [TimeSpan] = []
        var quiet: [TimeSpan] = []
        for run in runs(of: active.map { !$0 }, within: kept) {
            let still = runs(of: moving.map { !$0 }, within: run).filter { $0.duration >= minimumDead - 1e-9 }
            dead += still
            for piece in AgentEdits.gaps(between: still, within: run) where piece.duration >= minimumQuiet - 1e-9 {
                if screenSpans?.contains(where: { $0.intersection(piece) != nil }) == true {
                    quiet.append(piece)
                }
            }
        }
        dead.sort { $0.start < $1.start }
        quiet.sort { $0.start < $1.start }

        let focusEvents = input.focus ?? []
        let wanted = input.focusApp ?? AppFocusTimeline.dominantApp(focusEvents, duration: duration)
        // The app as recorded ("Slack" for "slack"). One that was never in front would
        // make the whole take a detour, so it finds none.
        let recordedApp = wanted.flatMap { name in focusEvents.first(where: { $0.isApp(name) })?.appName }
        let offApp = recordedApp.map {
            detours(from: $0, focus: focusEvents, kept: kept, speech: speech ?? [], duration: duration)
        } ?? []

        let deadCuts: [TimeSpan] = dead.compactMap { span in
            let cut = TimeSpan(start: span.start + cutMargin, end: span.end - cutMargin)
            return cut.duration >= minimumCut - 1e-9 ? cut : nil
        }
        let removed = AgentEdits.merged(deadCuts + offApp)
        let covers = recordedApp.map {
            self.covers(of: $0, focus: focusEvents, kept: kept, removed: removed, speech: speech ?? [], duration: duration)
        } ?? []
        let coverCuts = covers.filter { $0.action == .cut }.flatMap { cover in cover.pieces.map { $0.span } }
        let cuts = AgentEdits.merged(removed + coverCuts)
        // A wait during a detour goes with the detour.
        let waits = quiet.flatMap { AgentEdits.gaps(between: cuts, within: $0) }
        let speedUps: [TakeAnalysis.SpeedUp] = waits.compactMap { span in
            guard span.duration >= minimumSpeedUp - 1e-9 else { return nil }
            let speed = min(max((span.duration / quietTarget * 2).rounded() / 2, 2), 8)
            return TakeAnalysis.SpeedUp(span: span, speed: speed)
        }

        return TakeAnalysis(
            duration: duration,
            leadIn: kept.start > 0 ? TimeSpan(start: 0, end: kept.start) : nil,
            tail: kept.end < duration ? TimeSpan(start: kept.end, end: duration) : nil,
            dead: dead,
            quiet: quiet,
            offApp: offApp,
            covers: covers,
            focusApp: focusEvents.isEmpty ? nil : (recordedApp ?? wanted),
            apps: AppFocusTimeline.timeByApp(focusEvents, duration: duration).map {
                TakeAnalysis.AppShare(appName: $0.appName, seconds: $0.seconds)
            },
            speech: speech,
            screenActivity: screenSpans,
            beats: beats(clicks: clicks, keys: keys, frameSize: input.frameSize),
            kept: kept,
            cuts: cuts,
            speedUps: speedUps
        )
    }

    /// From just before the first action to the end of the last one (and what it set
    /// moving on screen). The whole take when nothing was clicked, typed or said.
    func keptRange(
        duration: TimeInterval,
        clicks: [ClickEvent],
        keys: [KeystrokeEvent],
        speech: [TimeSpan]?,
        screen: [TimeSpan]
    ) -> TimeSpan {
        let firsts: [TimeInterval] = [clicks.first?.timestamp, keys.first?.timestamp, speech?.first?.start].compactMap { $0 }
        let lasts: [TimeInterval] = [clicks.last?.timestamp, keys.last?.timestamp, speech?.last?.end].compactMap { $0 }
        guard let first = firsts.min(), let last = lasts.max() else {
            return TimeSpan(start: 0, end: duration)
        }
        var start = max(first - leadInMargin, 0)
        if start < minimumEdge {
            start = 0
        }
        var end = last + tailHold
        // Let what the last action started finish, like a page loading.
        if let settling = screen.first(where: { $0.end > last && $0.start <= last + 1 }) {
            end = max(end, min(settling.end + 0.3, last + maximumSettle))
        }
        if duration - end < minimumEdge {
            end = duration
        }
        guard end - start >= 1 else {
            return TimeSpan(start: 0, end: duration)
        }
        return TimeSpan(start: start, end: end)
    }

    /// Where another app than `app` was in front, inside `kept`, reaching
    /// `detourPadding` past it either side so none of it shows, and never cutting into
    /// speech (it may be narrating the detour).
    func detours(
        from app: String,
        focus: [AppFocusEvent],
        kept: TimeSpan,
        speech: [TimeSpan],
        duration: TimeInterval
    ) -> [TimeSpan] {
        let talking = AgentEdits.merged(speech.map { TimeSpan(start: $0.start - speechPadding, end: $0.end + speechPadding) })
        var result: [TimeSpan] = []
        for span in AppFocusTimeline.spans(focus, duration: duration) where !span.isApp(app) {
            let padded = TimeSpan(start: span.span.start - detourPadding, end: span.span.end + detourPadding)
            guard let inside = padded.intersection(kept) else { continue }
            for piece in AgentEdits.gaps(between: talking, within: inside) where piece.duration >= minimumDetour - 1e-9 {
                result.append(piece)
            }
        }
        return AgentEdits.merged(result)
    }

    /// Other apps' windows over `app`'s window inside `kept`, outside `removed`: windows
    /// over it while it was in front (cut when they hide a lot of it and nobody's talking,
    /// blurred otherwise), and other apps brought in front of it that weren't cut
    /// (while talking: kept).
    func covers(
        of app: String,
        focus: [AppFocusEvent],
        kept: TimeSpan,
        removed: [TimeSpan],
        speech: [TimeSpan],
        duration: TimeInterval
    ) -> [TakeAnalysis.Cover] {
        struct Sighting {
            var appName: String
            var inFront: Bool
            var piece: TakeAnalysis.Cover.Piece
        }

        let events = focus.sorted { $0.timestamp < $1.timestamp }
        // Where the app's window is; before it's first seen, where it was first seen.
        var window = events.first { $0.isApp(app) && $0.windowRect != nil }?.windowRect
        var sightings: [Sighting] = []
        for (index, event) in events.enumerated() {
            let end = index + 1 < events.count ? events[index + 1].timestamp : duration
            if event.isApp(app) {
                window = event.windowRect ?? window
            }
            guard end > event.timestamp, let frame = window else { continue }
            if event.isApp(app) {
                let span = TimeSpan(start: max(event.timestamp - coverLag, 0), end: end)
                for cover in event.covers {
                    if let piece = coverPiece(cover.rect, over: frame, span: span) {
                        sightings.append(Sighting(appName: cover.appName, inFront: false, piece: piece))
                    }
                }
            } else if let other = event.windowRect,
                      let piece = coverPiece(other, over: frame, span: TimeSpan(start: event.timestamp, end: end)) {
                sightings.append(Sighting(appName: event.appName, inFront: true, piece: piece))
            }
        }

        // Join sightings of one app close together into covers.
        var grouped: [(appName: String, inFront: Bool, pieces: [TakeAnalysis.Cover.Piece])] = []
        for sighting in sightings.sorted(by: { $0.piece.span.start < $1.piece.span.start }) {
            if let index = grouped.lastIndex(where: { group in
                group.appName == sighting.appName && group.inFront == sighting.inFront
                    && (group.pieces.last?.span.end ?? -Double.infinity) >= sighting.piece.span.start - coverJoin
            }) {
                grouped[index].pieces.append(sighting.piece)
            } else {
                grouped.append((sighting.appName, sighting.inFront, [sighting.piece]))
            }
        }

        let gone = AgentEdits.merged(removed)
        let talking = AgentEdits.merged(speech.map { TimeSpan(start: $0.start - speechPadding, end: $0.end + speechPadding) })
        var result: [TakeAnalysis.Cover] = []
        for group in grouped {
            // Only what's left in the video.
            let pieces = group.pieces.flatMap { piece -> [TakeAnalysis.Cover.Piece] in
                guard let inside = piece.span.intersection(kept) else { return [] }
                return AgentEdits.gaps(between: gone, within: inside)
                    .filter { $0.duration > 0.02 }
                    .map { TakeAnalysis.Cover.Piece(span: $0, rect: piece.rect, share: piece.share) }
            }
            guard let first = pieces.first, let last = pieces.last else { continue }
            let action: TakeAnalysis.Cover.Action
            if group.inFront {
                action = .keep
            } else if (pieces.map { $0.share }.max() ?? 0) >= bigCover,
                      !pieces.contains(where: { piece in talking.contains { $0.intersection(piece.span) != nil } }) {
                action = .cut
            } else {
                action = .blur
            }
            result.append(TakeAnalysis.Cover(
                appName: group.appName,
                span: TimeSpan(start: first.span.start, end: last.span.end),
                pieces: pieces,
                action: action
            ))
        }
        return result.sorted { $0.span.start < $1.span.start }
    }

    /// `rect` where it lies over `window`, with room for its shadow; `nil` when it hides
    /// less than `minimumCover` of the window.
    private func coverPiece(_ rect: CGRect, over window: CGRect, span: TimeSpan) -> TakeAnalysis.Cover.Piece? {
        let windowArea = Double(WindowStack.area(window))
        let hidden = rect.intersection(window)
        guard windowArea > 0, !hidden.isNull else { return nil }
        let share = Double(WindowStack.area(hidden)) / windowArea
        guard share >= minimumCover else { return nil }
        let padded = rect.insetBy(dx: -coverPadding, dy: -coverPadding).intersection(window)
        return TakeAnalysis.Cover.Piece(span: span, rect: padded.isNull ? hidden : padded, share: min(share, 1))
    }

    /// Clicks close together, typing, and shortcuts, in order.
    func beats(clicks: [ClickEvent], keys: [KeystrokeEvent], frameSize: CGSize) -> [TakeAnalysis.Beat] {
        var result: [TakeAnalysis.Beat] = []
        for group in grouped(clicks.map(\.timestamp), within: 0.6) {
            let members = clicks[group]
            let x = members.reduce(0) { $0 + Double($1.locationX) } / Double(members.count)
            let y = members.reduce(0) { $0 + Double($1.locationY) } / Double(members.count)
            var location: CGPoint?
            if frameSize.width > 0, frameSize.height > 0 {
                location = CGPoint(
                    x: min(max(x / Double(frameSize.width), 0), 1),
                    y: min(max(y / Double(frameSize.height), 0), 1)
                )
            }
            result.append(TakeAnalysis.Beat(
                kind: .clicks,
                span: TimeSpan(start: clicks[group.lowerBound].timestamp, end: clicks[group.upperBound - 1].timestamp),
                count: members.count,
                location: location
            ))
        }
        for group in grouped(keys.map(\.timestamp), within: 1) {
            let members = keys[group]
            let typed = members.filter { !$0.isShortcut }.count
            result.append(TakeAnalysis.Beat(
                kind: typed >= 3 ? .typing : .shortcut,
                span: TimeSpan(start: keys[group.lowerBound].timestamp, end: keys[group.upperBound - 1].timestamp),
                count: members.count,
                location: nil
            ))
        }
        return result.sorted { $0.span.start < $1.span.start }
    }

    // MARK: - Grid

    /// Marks the steps that overlap `start..<end`.
    private func mark(_ grid: inout [Bool], from start: TimeInterval, to end: TimeInterval) {
        guard !grid.isEmpty, end > start else { return }
        let first = max(0, Int((start / step + 1e-9).rounded(.down)))
        let last = min(grid.count - 1, Int((end / step - 1e-9).rounded(.up)) - 1)
        guard first <= last else { return }
        for index in first...last {
            grid[index] = true
        }
    }

    /// Marks steps where the pointer travelled further than the threshold.
    private func markCursor(_ events: [CursorEvent], frameSize: CGSize, in grid: inout [Bool]) {
        guard events.count > 1, !grid.isEmpty else { return }
        let sorted = events.sorted { $0.timestamp < $1.timestamp }
        let diagonal = hypot(Double(frameSize.width), Double(frameSize.height))
        let limit = diagonal > 0 ? cursorThreshold * diagonal : 7
        var travel = [Double](repeating: 0, count: grid.count)
        for (previous, next) in zip(sorted, sorted.dropFirst()) {
            let index = Int((next.timestamp / step + 1e-9).rounded(.down))
            guard index >= 0, index < travel.count else { continue }
            travel[index] += hypot(Double(next.locationX - previous.locationX), Double(next.locationY - previous.locationY))
        }
        for index in travel.indices where travel[index] >= limit {
            grid[index] = true
        }
    }

    /// Runs of `true` steps, as times clipped to `range`.
    private func runs(of grid: [Bool], within range: TimeSpan) -> [TimeSpan] {
        guard !grid.isEmpty, range.duration > 0 else { return [] }
        let first = max(0, Int((range.start / step + 1e-9).rounded(.down)))
        let last = min(grid.count, Int((range.end / step - 1e-9).rounded(.up)))
        var result: [TimeSpan] = []
        var runStart: Int?
        func close(at end: Int) {
            guard let start = runStart else { return }
            let span = TimeSpan(start: max(Double(start) * step, range.start), end: min(Double(end) * step, range.end))
            if span.duration > 0 {
                result.append(span)
            }
            runStart = nil
        }
        if first < last {
            for index in first..<last {
                if grid[index] {
                    if runStart == nil {
                        runStart = index
                    }
                } else {
                    close(at: index)
                }
            }
        }
        close(at: last)
        return result
    }

    /// Index ranges of sorted `times` whose neighbours are at most `gap` apart.
    private func grouped(_ times: [TimeInterval], within gap: TimeInterval) -> [Range<Int>] {
        guard !times.isEmpty else { return [] }
        var groups: [Range<Int>] = []
        var start = 0
        for index in times.indices.dropFirst() where times[index] - times[index - 1] > gap {
            groups.append(start..<index)
            start = index
        }
        groups.append(start..<times.count)
        return groups
    }
}
