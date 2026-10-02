import CoreGraphics
import Foundation
import Testing
@testable import RecorderCore

private let frame = CGSize(width: 1920, height: 1080)

private func click(_ time: TimeInterval, x: CGFloat = 960, y: CGFloat = 540) -> ClickEvent {
    ClickEvent(timestamp: time, location: CGPoint(x: x, y: y), button: .left)
}

private func input(
    duration: TimeInterval,
    clicks: [ClickEvent] = [],
    keys: [KeystrokeEvent] = [],
    cursor: [CursorEvent] = [],
    screen: [VisualChangeSample]? = nil,
    speech: [TimeSpan]? = nil,
    focus: [AppFocusEvent]? = nil,
    focusApp: String? = nil
) -> TakeAnalysisInput {
    TakeAnalysisInput(
        duration: duration,
        frameSize: frame,
        clicks: clicks,
        keystrokes: keys,
        cursor: cursor,
        screen: screen,
        speech: speech,
        focus: focus,
        focusApp: focusApp
    )
}

private func focus(_ time: TimeInterval, _ app: String, window: CGRect? = nil) -> AppFocusEvent {
    AppFocusEvent(timestamp: time, bundleID: "com.example.\(app.lowercased())", appName: app, windowRect: window)
}

/// Spans as [start, end] rounded to microseconds, for exact comparisons.
private func pairs(_ spans: [TimeSpan]) -> [[Double]] {
    spans.map { [($0.start * 1_000_000).rounded() / 1_000_000, ($0.end * 1_000_000).rounded() / 1_000_000] }
}

/// A screen that changes a lot every quarter second from `start` to `end`.
private func busyScreen(from start: Double, to end: Double) -> [VisualChangeSample] {
    stride(from: 0, through: Int(((end - start) * 4).rounded()), by: 1).map {
        VisualChangeSample(time: start + Double($0) / 4, area: 0.3)
    }
}

@Suite("Speech detection")
struct SpeechDetectorTests {
    private func levels(_ runs: [(level: Double, frames: Int)]) -> [Double] {
        runs.flatMap { Array(repeating: $0.level, count: $0.frames) }
    }

    @Test func findsSpeechAndBridgesShortPauses() {
        // 50 frames a second: noise, a sentence with a 0.2 s pause, noise, a 0.06 s click.
        let input = levels([(-60, 50), (-20, 50), (-60, 10), (-20, 25), (-60, 50), (-10, 3), (-60, 50)])
        let speech = SpeechDetector().speech(levels: input)
        #expect(speech.count == 1)
        #expect(isClose(speech[0].start, 1.0, tolerance: 1e-6) && isClose(speech[0].end, 2.7, tolerance: 1e-6))
    }

    @Test func speechCanStartRightAway() {
        let speech = SpeechDetector().speech(levels: levels([(-20, 100), (-60, 50)]), start: 0.5)
        #expect(pairs(speech) == [[0.5, 2.5]])
    }

    @Test func aQuietRoomIsNotSpeech() {
        // Far below the absolute threshold, however far above the floor.
        let speech = SpeechDetector().speech(levels: levels([(-110, 50), (-75, 50), (-110, 50)]))
        #expect(speech.isEmpty)
    }

    @Test func metersFramesAndPadsGaps() {
        var meter = LoudnessMeter(frameLength: 4)
        meter.add([1, 1, 1, 1])
        meter.add([0.5, 0.5])
        // Audio went missing until sample 20: silence keeps later levels in place.
        meter.pad(toSample: 20)
        meter.pad(toSample: 22)
        let levels = meter.finish()
        #expect(levels.count == 5)
        #expect(isClose(levels[0], 0))
        #expect(isClose(levels[1], 20 * log10((0.5 / 4).squareRoot())))
        #expect(levels[2] == SpeechDetector.silence)
        #expect(meter.position == 20)
    }
}

@Suite("Screen changes")
struct VisualChangeTests {
    @Test func countsPixelsThatChanged() {
        let before: [UInt8] = [0, 0, 0, 0, 100, 100, 100, 100]
        let after: [UInt8] = [0, 5, 20, 0, 100, 100, 0, 100]
        #expect(VisualChange.changedArea(before, after) == 0.25)
        #expect(VisualChange.changedArea(before, [0, 0]) == 1)
        #expect(VisualChange.changedArea([], []) == 0)
    }

    @Test func samplesAtMostFourFramesASecond() {
        let times = (0..<40).map { Double($0) / 20 }
        #expect(VisualChange.sampleIndices(frameTimes: times, duration: 2) == [0, 5, 10, 15, 20, 25, 30, 35])
        // Long takes widen the slots to stay under the limit.
        #expect(VisualChange.sampleIndices(frameTimes: times, duration: 2, limit: 3) == [0, 14, 27])
        #expect(VisualChange.sampleIndices(frameTimes: [], duration: 2).isEmpty)
    }

    @Test func joinsChangesCloseTogether() {
        let samples = [
            VisualChangeSample(time: 1.0, area: 0.3),
            VisualChangeSample(time: 1.25, area: 0.4),
            VisualChangeSample(time: 1.5, area: 0.001),
            VisualChangeSample(time: 1.75, area: 0.2),
            VisualChangeSample(time: 4.0, area: 0.5)
        ]
        #expect(pairs(VisualChange.movingSpans(samples)) == [[1.0, 2.0], [4.0, 4.25]])
    }
}

@Suite("Take analysis")
struct TakeAnalyzerTests {
    @Test func findsTheLeadInAndTailAndIgnoresTheStopClick() {
        let analysis = TakeAnalyzer().analyze(input(duration: 12, clicks: [click(3), click(5), click(8), click(11.7)]))
        #expect(pairs([analysis.kept]) == [[2.5, 8.8]])
        #expect(pairs(analysis.leadIn.map { [$0] } ?? []) == [[0, 2.5]])
        #expect(pairs(analysis.tail.map { [$0] } ?? []) == [[8.8, 12]])
        // 3.6–4.7 is too short to be dead air; 5.6–7.7 isn't.
        #expect(pairs(analysis.dead) == [[5.6, 7.7]])
        #expect(pairs(analysis.cuts) == [[5.8, 7.5]])
        #expect(analysis.quiet.isEmpty)
        #expect(isClose(analysis.suggestedTimeline().outputDuration, 4.6, tolerance: 1e-6))
        #expect(analysis.beats.map(\.kind) == [.clicks, .clicks, .clicks])
        let location = analysis.beats.first?.location
        #expect(location.map { isClose($0.x, 0.5) && isClose($0.y, 0.5) } == true)
    }

    @Test func aMovingScreenIsAWaitNotDeadAir() {
        let analysis = TakeAnalyzer().analyze(input(
            duration: 13,
            clicks: [click(1.5), click(10)],
            screen: busyScreen(from: 4, to: 7) + [VisualChangeSample(time: 2.5, area: 0.0005)]
        ))
        #expect(pairs([analysis.kept]) == [[1.0, 10.8]])
        #expect(pairs(analysis.dead) == [[2.1, 4.0], [7.3, 9.7]])
        #expect(pairs(analysis.quiet) == [[4.0, 7.3]])
        #expect(pairs(analysis.cuts) == [[2.3, 3.8], [7.5, 9.5]])
        #expect(analysis.speedUps.map(\.speed) == [4])
        #expect(isClose(analysis.suggestedTimeline().outputDuration, 3.825, tolerance: 1e-6))
        #expect(analysis.summary.hasSuffix("Suggested edit: 13.0 s → 3.8 s."))
    }

    @Test func speechIsNeverCut() {
        let speech = TimeSpan(start: 4.5, end: 9)
        let analysis = TakeAnalyzer().analyze(input(
            duration: 14,
            clicks: [click(2), click(12)],
            screen: [],
            speech: [speech]
        ))
        #expect(pairs(analysis.dead) == [[2.6, 4.3], [9.2, 11.7]])
        #expect(analysis.cuts.count == 2)
        for cut in analysis.cuts {
            #expect(cut.intersection(speech) == nil)
        }
        // Scanned, and nothing moved.
        #expect(analysis.quiet.isEmpty)
        #expect(analysis.screenActivity == [])
    }

    @Test func pointerMovementCountsButJitterDoesNot() {
        let jitter = (0...40).map { step in
            CursorEvent(timestamp: 2.5 + Double(step) * 0.05, location: CGPoint(x: 100 + CGFloat(step % 2), y: 100))
        }
        let travel = (1...40).map { step in
            CursorEvent(timestamp: 5.0 + Double(step) * 0.05, location: CGPoint(x: 100 + CGFloat(step) * 40, y: 100))
        }
        let analysis = TakeAnalyzer().analyze(input(duration: 10, clicks: [click(1.5), click(8.5)], cursor: jitter + travel))
        // The jitter is dead air; the reach for the button isn't, and what's left after it
        // is too short.
        #expect(pairs(analysis.dead) == [[2.1, 5.0]])
    }

    @Test func groupsBeats() {
        let typing = (0..<5).map { KeystrokeEvent(timestamp: 5 + Double($0) / 10, keyCode: 0x04, modifiers: 0, characters: "h") }
        let save = KeystrokeEvent(timestamp: 8, keyCode: 0x01, modifiers: KeyCombo.Modifier.command, characters: "s")
        let analysis = TakeAnalyzer().analyze(input(
            duration: 10,
            clicks: [click(3, x: 480, y: 270), click(3.3, x: 480, y: 270)],
            keys: typing + [save]
        ))
        #expect(analysis.beats.map(\.kind) == [.clicks, .typing, .shortcut])
        #expect(analysis.beats.map(\.count) == [2, 5, 1])
        let location = analysis.beats.first?.location
        #expect(location.map { isClose($0.x, 0.25) && isClose($0.y, 0.25) } == true)
    }

    /// Busy all along (a click every 0.8 s), with Slack in front from 6 s to 10 s.
    private func detourTake(speech: [TimeSpan]? = nil, focusApp: String? = nil) -> TakeAnalysis {
        let clicks = (0...15).map { click(2 + Double($0) * 0.8) }
        let events = [focus(0, "Acme"), focus(6, "Slack"), focus(10, "Acme")]
        return TakeAnalyzer().analyze(input(duration: 20, clicks: clicks, speech: speech, focus: events, focusApp: focusApp))
    }

    @Test func detoursToOtherAppsAreCut() throws {
        let analysis = detourTake()
        #expect(pairs([analysis.kept]) == [[1.5, 14.8]])
        #expect(analysis.dead.isEmpty)
        #expect(analysis.focusApp == "Acme")
        #expect(analysis.apps.map(\.appName) == ["Acme", "Slack"])
        // Slack was in front 6–10 s: the cut reaches a moment past it either side, so none
        // of it shows.
        #expect(pairs(analysis.offApp) == [[5.95, 10.05]])
        #expect(pairs(analysis.cuts) == [[5.95, 10.05]])
        #expect(isClose(analysis.suggestedTimeline().outputDuration, 9.2, tolerance: 1e-6))
        #expect(analysis.summary.contains("1 detour away from Acme (4.1 s)"))

        let report = analysis.json
        #expect(report["focus_app"]?.stringValue == "Acme")
        #expect(report["off_app"]?.arrayValue?.count == 1)
        #expect(report["apps"]?.arrayValue?.first?["name"]?.stringValue == "Acme")
        let operations = try #require(report["suggested"]?["operations"]?.arrayValue)
        #expect(operations.compactMap { $0["op"]?.stringValue } == ["reset", "trim", "cut"])
    }

    @Test func aDetourIsNotCutWhileTalking() {
        // Explaining the detour: the talking (with a little room) stays, the rest goes.
        let analysis = detourTake(speech: [TimeSpan(start: 7, end: 8)])
        #expect(pairs(analysis.offApp) == [[5.95, 6.85], [8.15, 10.05]])
    }

    @Test func theAppCanBeNamed() {
        // About Slack: the Acme stretches are the detours.
        let analysis = detourTake(focusApp: "slack")
        #expect(analysis.focusApp == "Slack")
        #expect(pairs(analysis.offApp) == [[1.5, 6.05], [9.95, 14.8]])
        // An app that was never in front doesn't make the whole take a detour.
        let unknown = detourTake(focusApp: "Figma")
        #expect(unknown.offApp.isEmpty && unknown.cuts.isEmpty)
    }

    @Test func aWaitDuringADetourGoesWithIt() {
        // A page loading in Slack from 6 s to 10 s, with nobody acting.
        let clicks = [2, 2.8, 3.6, 4.4, 5.2, 10.4, 11.2, 12].map { click($0) }
        let screen = busyScreen(from: 6, to: 9.75)
        let alone = TakeAnalyzer().analyze(input(duration: 14, clicks: clicks, screen: screen))
        #expect(pairs(alone.quiet) == [[5.8, 10.1]])
        #expect(alone.speedUps.map(\.speed) == [5.5])

        let events = [focus(0, "Acme"), focus(6, "Slack"), focus(10, "Acme")]
        let analysis = TakeAnalyzer().analyze(input(duration: 14, clicks: clicks, screen: screen, focus: events))
        #expect(pairs(analysis.cuts) == [[5.95, 10.05]])
        // What's left of the wait either side of the cut is too short to speed up.
        #expect(analysis.speedUps.isEmpty)
    }

    private func coveredTake(speech: [TimeSpan]? = nil) -> TakeAnalysis {
        let clicks = (0...15).map { click(2 + Double($0) * 0.8) }
        let window = CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.6)
        func acme(_ time: TimeInterval, _ covers: [WindowCover] = []) -> AppFocusEvent {
            AppFocusEvent(timestamp: time, bundleID: "com.example.acme", appName: "Acme", windowRect: window, covers: covers)
        }
        let banner = WindowCover(appName: "Messages", bundleID: nil, rect: CGRect(x: 0.55, y: 0.6, width: 0.2, height: 0.08))
        let call = WindowCover(appName: "Zoom", bundleID: nil, rect: CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4))
        let events = [
            acme(0),
            acme(4, [banner]),
            acme(6),
            acme(8, [call]),
            acme(9),
            AppFocusEvent(timestamp: 11, bundleID: nil, appName: "Slack", windowRect: CGRect(x: 0.3, y: 0.3, width: 0.5, height: 0.5)),
            acme(12)
        ]
        return TakeAnalyzer().analyze(input(duration: 20, clicks: clicks, speech: speech, focus: events))
    }

    @Test func otherAppsOverTheWindowAreBlurredOrCut() throws {
        let analysis = coveredTake()
        try #require(analysis.covers.count == 2)
        // A notification over a corner of the window: blurred where it lay over it (with
        // room for its shadow), from a moment before it was seen.
        let banner = analysis.covers[0]
        #expect(banner.appName == "Messages" && banner.action == .blur)
        #expect(pairs([banner.span]) == [[3.75, 6]])
        #expect(isClose(banner.share, 0.012 / 0.36, tolerance: 1e-6))
        #expect(banner.pieces.map { isClose($0.rect, CGRect(x: 0.544, y: 0.594, width: 0.156, height: 0.092)) } == [true])
        // A call window over most of it, with nobody talking: cut.
        let call = analysis.covers[1]
        #expect(call.appName == "Zoom" && call.action == .cut)
        #expect(isClose(call.share, 0.16 / 0.36, tolerance: 1e-6))
        // Slack brought in front is a detour, cut as before; not a cover.
        #expect(pairs(analysis.offApp) == [[10.95, 12.05]])
        #expect(pairs(analysis.cuts) == [[7.75, 9], [10.95, 12.05]])

        let report = analysis.json
        #expect(report["covers"]?.arrayValue?.compactMap { $0["action"]?.stringValue } == ["blur", "cut"])
        let blurs = try #require(report["suggested"]?["blur_operations"]?.arrayValue)
        #expect(blurs.count == 1)
        // Origin top-left for agents: the box's top is 1 - 0.686 from the top.
        #expect(blurs.first?["rect"]?["y"]?.doubleValue.map { isClose($0, 0.314, tolerance: 1e-6) } == true)
        #expect(analysis.summary.contains("2 other apps over Acme (1 cut, 1 blurred)"))

        // edit_blur takes the suggested operations as they are.
        var settings = ProjectEditSettings()
        settings.setTimeline(EditTimeline(sourceDuration: 20))
        var snapshot = EditorSnapshot(keyframes: [], editSettings: settings)
        _ = try AgentEdits.editBlur(&snapshot, operations: blurs.map { AgentArguments($0) }, take: AgentEditTake(duration: 20, sourceSize: frame), timeBase: .source)
        #expect(snapshot.editSettings.blurRegions.map { isClose($0.rect, banner.pieces[0].rect, tolerance: 1e-6) } == [true])
    }

    @Test func coversAreNotCutWhileTalking() throws {
        // Talking over the call window, and while Slack is in front.
        let analysis = coveredTake(speech: [TimeSpan(start: 8.2, end: 8.6), TimeSpan(start: 11.2, end: 11.6)])
        try #require(analysis.covers.count == 3)
        #expect(analysis.covers.map(\.action) == [.blur, .blur, .keep])
        // What's left of Slack is the part being talked over.
        let slack = analysis.covers[2]
        #expect(slack.appName == "Slack")
        #expect(pairs([slack.span]) == [[11.05, 11.75]])
        #expect(pairs(analysis.offApp) == [[10.95, 11.05], [11.75, 12.05]])
        #expect(!analysis.cuts.contains { $0.intersection(TimeSpan(start: 8, end: 9)) != nil })
        #expect(analysis.summary.contains("3 other apps over Acme (2 blurred, 1 kept while talking)"))
    }

    @Test func aTakeWithNothingDoneIsKeptWhole() {
        let analysis = TakeAnalyzer().analyze(input(duration: 6))
        #expect(pairs([analysis.kept]) == [[0, 6]])
        #expect(analysis.leadIn == nil && analysis.tail == nil)
    }

    @Test func theSuggestedOperationsMakeTheSuggestedEdit() throws {
        let analysis = TakeAnalyzer().analyze(input(
            duration: 13,
            clicks: [click(1.5), click(10)],
            screen: busyScreen(from: 4, to: 7)
        ))
        let report = analysis.json
        let operations = try #require(report["suggested"]?["operations"]?.arrayValue)
        #expect(operations.compactMap { $0["op"]?.stringValue } == ["reset", "trim", "cut", "cut", "speed"])
        #expect(report["speech"]?.stringValue == "No microphone was recorded.")
        #expect(report["screen_scanned"]?.boolValue == true)
        #expect(report["focus_app"]?.stringValue?.hasPrefix("Unknown") == true)
        #expect(report["off_app"] == nil)
        #expect(report["beats"]?.arrayValue?.first?["point"]?["y"]?.doubleValue == 0.5)

        // Through edit_timeline's own code, they give the edit the analysis described.
        var settings = ProjectEditSettings()
        settings.setTimeline(EditTimeline(sourceDuration: 13))
        var snapshot = EditorSnapshot(keyframes: [], editSettings: settings)
        _ = try AgentEdits.editTimeline(
            &snapshot,
            operations: operations.map { AgentArguments($0) },
            take: AgentEditTake(duration: 13, sourceSize: frame),
            timeBase: .source
        )
        let edited = snapshot.editSettings.resolvedTimeline(sourceDuration: 13).outputDuration
        #expect(isClose(edited, analysis.suggestedTimeline().outputDuration, tolerance: 0.01))
    }
}

@Suite("App focus")
struct AppFocusTests {
    @Test func notesOnlyChanges() {
        var events: [AppFocusEvent] = []
        let window = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        AppFocusTimeline.append(focus(0, "Acme", window: window), to: &events)
        // The same window, give or take a pixel: nothing new.
        AppFocusTimeline.append(focus(0.25, "Acme", window: window.offsetBy(dx: 0.001, dy: 0)), to: &events)
        // The window moved.
        AppFocusTimeline.append(focus(0.5, "Acme", window: window.offsetBy(dx: 0.2, dy: 0)), to: &events)
        AppFocusTimeline.append(focus(0.75, "Slack"), to: &events)
        AppFocusTimeline.append(focus(1, "Slack"), to: &events)
        #expect(events.map(\.timestamp) == [0, 0.5, 0.75])
    }

    @Test func readsWhoWasInFrontAndWhere() throws {
        let events = [
            focus(0, "Acme", window: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6)),
            focus(2, "Acme", window: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.6)),
            focus(5, "Slack", window: CGRect(x: 0, y: 0, width: 1, height: 1)),
            focus(9, "Acme")
        ]
        let spans = AppFocusTimeline.spans(events, duration: 12)
        #expect(spans.map(\.appName) == ["Acme", "Slack", "Acme"])
        #expect(pairs(spans.map(\.span)) == [[0, 5], [5, 9], [9, 12]])

        let shares = AppFocusTimeline.timeByApp(events, duration: 12)
        try #require(shares.count == 2)
        #expect(shares[0].appName == "Acme" && isClose(shares[0].seconds, 8))
        #expect(shares[1].appName == "Slack" && isClose(shares[1].seconds, 4))
        #expect(AppFocusTimeline.dominantApp(events, duration: 12) == "Acme")
        #expect(AppFocusTimeline.dominantApp([], duration: 12) == nil)
        #expect(AppFocusTimeline.quotedNames(events, duration: 12) == "\"Acme\", \"Slack\"")

        // Everywhere Acme's window was, by name or bundle ID, ignoring case and spaces.
        let union = try #require(AppFocusTimeline.windowUnion(of: " acme ", in: events))
        #expect(isClose(union, CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.6)))
        #expect(AppFocusTimeline.windowUnion(of: "COM.EXAMPLE.ACME", in: events) == union)
        #expect(AppFocusTimeline.windowUnion(of: "Figma", in: events) == nil)
        #expect(!AppFocusTimeline.matches("", appName: "Acme", bundleID: nil))
    }

    @Test func placesWindowsInTheRecording() throws {
        // A Retina capture of the main display: 100, 50 points from the top-left is
        // 200, 100 pixels; the window's bottom edge is 380 pixels from the bottom.
        let window = try #require(CaptureGeometry.normalizedCaptureRect(
            global: CGRect(x: 100, y: 50, width: 400, height: 300),
            origin: .zero,
            scale: 2,
            pixelSize: CGSize(width: 1920, height: 1080)
        ))
        #expect(isClose(window, CGRect(x: 200.0 / 1920, y: 380.0 / 1080, width: 800.0 / 1920, height: 600.0 / 1080)))

        // A display left of the main one has a negative origin.
        let left = try #require(CaptureGeometry.normalizedCaptureRect(
            global: CGRect(x: -1000, y: 100, width: 200, height: 100),
            origin: CGPoint(x: -1440, y: 0),
            scale: 1,
            pixelSize: CGSize(width: 1440, height: 900)
        ))
        #expect(isClose(left, CGRect(x: 440.0 / 1440, y: 700.0 / 900, width: 200.0 / 1440, height: 100.0 / 900)))

        // Partly outside: clipped. Wholly outside: not in the recording.
        let clipped = try #require(CaptureGeometry.normalizedCaptureRect(
            global: CGRect(x: -100, y: 0, width: 400, height: 300),
            origin: .zero,
            scale: 1,
            pixelSize: CGSize(width: 1000, height: 500)
        ))
        #expect(isClose(clipped, CGRect(x: 0, y: 0.4, width: 0.3, height: 0.6)))
        #expect(CaptureGeometry.normalizedCaptureRect(
            global: CGRect(x: 2000, y: 0, width: 100, height: 100),
            origin: .zero,
            scale: 1,
            pixelSize: CGSize(width: 1000, height: 500)
        ) == nil)
    }

    @Test func isSavedWithTheInputs() throws {
        var covered = focus(0, "Acme", window: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6))
        covered.covers = [WindowCover(appName: "Messages", bundleID: "com.apple.MobileSMS", rect: CGRect(x: 0.4, y: 0.6, width: 0.2, height: 0.1))]
        let log = InputLog(appFocus: [covered, focus(3, "Slack")])
        let decoded = try JSONDecoder().decode(InputLog.self, from: JSONEncoder().encode(log))
        #expect(decoded == log)
        // Older takes have none.
        let older = try JSONDecoder().decode(InputLog.self, from: Data(#"{"keystrokes":[]}"#.utf8))
        #expect(older.appFocus.isEmpty)
        // An event without a window, bundle ID or covers still reads…
        let sparse = try JSONDecoder().decode(AppFocusEvent.self, from: Data(#"{"timestamp":1.5,"appName":"Acme"}"#.utf8))
        #expect(sparse == AppFocusEvent(timestamp: 1.5, bundleID: nil, appName: "Acme", windowRect: nil))
        // …and a moment without covers leaves the key out.
        let plain = try #require(String(data: JSONEncoder().encode(focus(2, "Acme")), encoding: .utf8))
        #expect(!plain.contains("covers"))
    }

    @Test func notesWhenSomethingCoversTheWindow() {
        var events: [AppFocusEvent] = []
        let window = CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.6)
        var event = focus(0, "Acme", window: window)
        AppFocusTimeline.append(event, to: &events)
        let banner = WindowCover(appName: "Messages", bundleID: nil, rect: CGRect(x: 0.5, y: 0.6, width: 0.2, height: 0.1))
        event.timestamp = 0.25
        event.covers = [banner]
        AppFocusTimeline.append(event, to: &events)
        // Still there, give or take a pixel: nothing new.
        event.timestamp = 0.5
        event.covers = [WindowCover(appName: "Messages", bundleID: nil, rect: banner.rect.offsetBy(dx: 0.001, dy: 0))]
        AppFocusTimeline.append(event, to: &events)
        // It moved, then went.
        event.timestamp = 0.75
        event.covers = [WindowCover(appName: "Messages", bundleID: nil, rect: banner.rect.offsetBy(dx: 0, dy: -0.2))]
        AppFocusTimeline.append(event, to: &events)
        event.timestamp = 1
        event.covers = []
        AppFocusTimeline.append(event, to: &events)
        #expect(events.map(\.timestamp) == [0, 0.25, 0.75, 1])
    }
}

@Suite("Window stack")
struct WindowStackTests {
    private let acme: Int32 = 10
    private let document = WindowSnapshot(windowID: 1, layer: 0, bounds: CGRect(x: 100, y: 100, width: 1200, height: 800), ownerPID: 10)

    @Test func findsTheAppsWindowInFront() {
        let palette = WindowSnapshot(windowID: 2, layer: 3, bounds: CGRect(x: 0, y: 0, width: 300, height: 600), ownerPID: acme)
        let sliver = WindowSnapshot(windowID: 3, layer: 0, bounds: CGRect(x: 0, y: 0, width: 600, height: 20), ownerPID: acme)
        let other = WindowSnapshot(windowID: 4, layer: 0, bounds: CGRect(x: 50, y: 50, width: 900, height: 700), ownerPID: 20)
        let second = WindowSnapshot(windowID: 5, layer: 0, bounds: CGRect(x: 1400, y: 100, width: 800, height: 600), ownerPID: acme)
        // Floating palettes and slivers don't count; other apps' windows aren't its own.
        #expect(WindowStack.frontWindow(of: acme, frontToBack: [palette, sliver, other, document, second]) == document)
        #expect(WindowStack.frontWindow(of: acme, frontToBack: [second, document]) == second)
        #expect(WindowStack.frontWindow(of: 99, frontToBack: [document]) == nil)

        // A sheet sits in its document window: the document window is the one shown.
        let sheet = WindowSnapshot(windowID: 6, layer: 0, bounds: CGRect(x: 400, y: 130, width: 600, height: 400), ownerPID: acme)
        #expect(WindowStack.frontWindow(of: acme, frontToBack: [sheet, document, second]) == document)
        // A small window beside it is a window of its own.
        let beside = WindowSnapshot(windowID: 7, layer: 0, bounds: CGRect(x: 1250, y: 100, width: 400, height: 300), ownerPID: acme)
        #expect(WindowStack.frontWindow(of: acme, frontToBack: [beside, document]) == beside)
    }

    @Test func findsWhatCoversIt() {
        func window(_ id: UInt32, layer: Int = 0, _ bounds: CGRect, pid: Int32 = 20, alpha: Double = 1, shared: Bool = true) -> WindowSnapshot {
            WindowSnapshot(windowID: id, layer: layer, bounds: bounds, ownerPID: pid, alpha: alpha, isShared: shared)
        }
        let corner = CGRect(x: 1000, y: 120, width: 360, height: 80)
        let banner = window(10, layer: 3, corner)
        let menu = window(11, layer: 101, CGRect(x: 600, y: 0, width: 240, height: 300), pid: 21)
        let menuBar = window(12, layer: 24, CGRect(x: 0, y: 0, width: 2000, height: 140), pid: 22)
        let statusItem = window(13, layer: 25, CGRect(x: 700, y: 0, width: 40, height: 140), pid: 23)
        let clear = window(14, layer: 3, corner, pid: 24, alpha: 0)
        let unshared = window(15, layer: 3, corner, pid: 25, shared: false)
        let overlay = window(16, layer: 20, CGRect(x: 0, y: 0, width: 2000, height: 1200), pid: 26)
        let trace = window(17, layer: 3, corner, pid: 30)
        let ownPanel = window(18, layer: 3, corner, pid: acme)
        let elsewhere = window(19, layer: 3, CGRect(x: 1500, y: 1000, width: 100, height: 100))
        let bigger = window(20, CGRect(x: 0, y: 0, width: 1600, height: 1000), pid: 27)
        let behind = window(21, CGRect(x: 200, y: 200, width: 400, height: 400), pid: 28)
        let stack = [banner, menu, menuBar, statusItem, clear, unshared, overlay, trace, ownPanel, elsewhere, bigger, document, behind]

        let covers = WindowStack.covers(of: document, frontToBack: stack, ignoredPIDs: [30])
        // In front and overlapping, seen in recordings: a banner, a menu and an ordinary
        // window over all of it. Not the menu bar or status items, see-through, unshared or
        // ignored windows, overlays over everything, its own windows, ones elsewhere or
        // ones behind it.
        #expect(covers.map(\.windowID) == [10, 11, 20])
        #expect(WindowStack.covers(of: document, frontToBack: [banner]).isEmpty)
    }
}
