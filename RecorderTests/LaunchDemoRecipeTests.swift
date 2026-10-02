import CoreGraphics
import Foundation
import Testing
@testable import RecorderCore

private let source = CGSize(width: 2000, height: 1000)

/// An analysis with exactly these findings (no screen scan, no microphone).
private func analysis(
    duration: TimeInterval = 30,
    kept: TimeSpan = TimeSpan(start: 2, end: 27),
    dead: [TimeSpan] = [],
    offApp: [TimeSpan] = [],
    focusApp: String? = nil,
    speedUps: [TakeAnalysis.SpeedUp] = [],
    beats: [TimeInterval] = []
) -> TakeAnalysis {
    TakeAnalysis(
        duration: duration,
        leadIn: kept.start > 0 ? TimeSpan(start: 0, end: kept.start) : nil,
        tail: kept.end < duration ? TimeSpan(start: kept.end, end: duration) : nil,
        dead: dead,
        quiet: speedUps.map(\.span),
        offApp: offApp,
        focusApp: focusApp,
        speech: nil,
        screenActivity: nil,
        beats: beats.map { TakeAnalysis.Beat(kind: .clicks, span: TimeSpan(start: $0, end: $0 + 0.2), count: 1, location: nil) },
        kept: kept,
        cuts: [],
        speedUps: speedUps
    )
}

private func blank(duration: TimeInterval = 30) -> EditorSnapshot {
    var settings = ProjectEditSettings()
    settings.setTimeline(EditTimeline(sourceDuration: duration))
    return EditorSnapshot(keyframes: [], editSettings: settings)
}

private func take(duration: TimeInterval = 30, focus: [AppFocusEvent] = []) -> AgentEditTake {
    AgentEditTake(
        duration: duration,
        sourceSize: source,
        clicks: [ClickEvent(timestamp: 8, location: CGPoint(x: 500, y: 500), button: .left)],
        appFocus: focus
    )
}

/// Spans as [start, end] rounded to microseconds, for exact comparisons.
private func pairs(_ spans: [TimeSpan?]) -> [[Double]?] {
    spans.map { span in
        span.map { [($0.start * 1_000_000).rounded() / 1_000_000, ($0.end * 1_000_000).rounded() / 1_000_000] }
    }
}

private func failure(_ body: () throws -> Void) -> String? {
    do {
        try body()
        return nil
    } catch let error as AgentToolError {
        return error.message
    } catch {
        return "\(error)"
    }
}

@Suite("Launch demo recipe")
struct LaunchDemoRecipeTests {
    @Test func cutsTheStoryTogether() throws {
        let findings = analysis(
            // A short pause stays as breathing room; a long one goes.
            dead: [TimeSpan(start: 5, end: 6.2), TimeSpan(start: 10, end: 13)],
            offApp: [TimeSpan(start: 15.2, end: 18.8)],
            speedUps: [TakeAnalysis.SpeedUp(span: TimeSpan(start: 20, end: 23), speed: 2)]
        )
        var snapshot = blank()
        let report = try LaunchDemoRecipe(options: LaunchDemoOptions()).apply(to: &snapshot, take: take(), analysis: findings)

        #expect(pairs(report.cuts) == [[10.2, 12.8], [15.2, 18.8]])
        // Waits play at least 4× at the snappy pace.
        #expect(report.speedUps.map(\.speed) == [4])
        let timeline = snapshot.editSettings.resolvedTimeline(sourceDuration: 30)
        #expect(isClose(timeline.trimStart, 2) && isClose(timeline.trimEnd, 27))
        #expect(timeline.speedRamp == SpeedRamp.defaultRamp)
        // 25 s kept, 6.2 s cut, 3 s played in 0.75 s.
        #expect(isClose(timeline.outputDuration, 16.55, tolerance: 1e-6))
        #expect(isClose(report.outputDuration, timeline.outputDuration))
        #expect(report.changes.first?.hasPrefix("Rebuilt the edit from the whole recording: 30.0 s → ") == true)
        #expect(report.changes.contains("Trimmed the lead-in (2.0 s) and the tail (3.0 s)."))
        #expect(report.changes.contains("Cut 1 pause (2.6 s) and 1 detour to other apps (3.6 s)."))
        #expect(report.changes.contains("Sped through 1 wait at 4×, easing in and out."))

        // Motion, transitions and audio at cuts.
        let settings = snapshot.editSettings
        #expect(settings.cutTransition == CutTransition(style: .zoomBlur, duration: 0.4))
        #expect(settings.audio.cutFades && settings.audio.muteSpedUp)
        #expect(settings.exportStyle.motionBlurEnabled && settings.exportStyle.springCameraEnabled)
        #expect(settings.zoomPreset == .demo)
        #expect(snapshot.keyframes.filter { $0.source == .auto }.count == 1)

        // It opens with a tilt in, inside the first segment.
        let tilt = try #require(settings.cameraMoves.first)
        #expect(settings.cameraMoves.count == 1 && tilt.kind == .tiltIn)
        #expect(isClose(tilt.span.start, 2) && isClose(tilt.span.end, 3.4))

        // Without focus data or text, it says how to finish.
        #expect(settings.sourceCrop == nil)
        #expect(report.suggestions.contains { $0.hasPrefix("This take doesn't record which app was in front") })
        #expect(report.suggestions.contains { $0.hasPrefix("No title or captions were given") })
    }

    @Test func thePaceSetsHowTightItIs() throws {
        let findings = analysis(
            dead: [TimeSpan(start: 5, end: 6.4), TimeSpan(start: 10, end: 12)],
            speedUps: [TakeAnalysis.SpeedUp(span: TimeSpan(start: 20, end: 23), speed: 2)]
        )
        func cut(_ pace: LaunchDemoPace) throws -> LaunchDemoReport {
            var snapshot = blank()
            var options = LaunchDemoOptions()
            options.pace = pace
            options.transition = nil
            let report = try LaunchDemoRecipe(options: options).apply(to: &snapshot, take: take(), analysis: findings)
            #expect(snapshot.editSettings.cutTransition == nil)
            #expect(snapshot.editSettings.zoomPreset == pace.zoomPreset)
            return report
        }
        let relaxed = try cut(.relaxed)
        #expect(relaxed.cuts.isEmpty && relaxed.speedUps.map(\.speed) == [2])
        let snappy = try cut(.snappy)
        #expect(pairs(snappy.cuts) == [[10.2, 11.8]])
        let punchy = try cut(.punchy)
        #expect(pairs(punchy.cuts) == [[5.2, 6.2], [10.2, 11.8]])
        #expect(punchy.speedUps.map(\.speed) == [6])
    }

    @Test func cropsToTheAppsWindow() throws {
        let focus = [
            AppFocusEvent(timestamp: 0, bundleID: "com.acme.app", appName: "Acme", windowRect: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6)),
            AppFocusEvent(timestamp: 16, bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", windowRect: CGRect(x: 0.5, y: 0, width: 0.4, height: 1)),
            AppFocusEvent(timestamp: 19, bundleID: "com.acme.app", appName: "Acme", windowRect: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6))
        ]
        let findings = analysis(offApp: [TimeSpan(start: 16.2, end: 18.8)], focusApp: "Acme")
        var snapshot = blank()
        let report = try LaunchDemoRecipe(options: LaunchDemoOptions()).apply(to: &snapshot, take: take(focus: focus), analysis: findings)
        #expect(snapshot.editSettings.sourceCrop.map { isClose($0, CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6)) } == true)
        #expect(report.croppedTo == "Acme")
        #expect(report.changes.contains("Cropped to Acme's window (1000×600 px)."))

        // Named, in any case.
        var other = blank()
        var options = LaunchDemoOptions()
        options.app = "slack"
        let slack = try LaunchDemoRecipe(options: options).apply(to: &other, take: take(focus: focus), analysis: findings)
        #expect(slack.croppedTo == "Slack")
        #expect(other.editSettings.sourceCrop.map { isClose($0, CGRect(x: 0.5, y: 0, width: 0.4, height: 1)) } == true)

        // Or left alone.
        var uncropped = blank()
        options.cropToApp = false
        _ = try LaunchDemoRecipe(options: options).apply(to: &uncropped, take: take(focus: focus), analysis: findings)
        #expect(uncropped.editSettings.sourceCrop == nil)
    }

    @Test func aWindowFillingTheRecordingIsNotCropped() throws {
        let focus = [AppFocusEvent(timestamp: 0, bundleID: nil, appName: "Acme", windowRect: CGRect(x: 0, y: 0, width: 1, height: 1))]
        var snapshot = blank()
        let report = try LaunchDemoRecipe(options: LaunchDemoOptions())
            .apply(to: &snapshot, take: take(focus: focus), analysis: analysis(focusApp: "Acme"))
        #expect(snapshot.editSettings.sourceCrop == nil && report.croppedTo == nil)
        #expect(report.changes.contains("Acme's window fills the recording, so it isn't cropped."))
    }

    @Test func placesTheTitleTaglineAndCaptions() throws {
        var options = LaunchDemoOptions()
        options.title = "Acme 2.0"
        options.tagline = "Ship demos in minutes"
        options.captions = [
            LaunchDemoCaption(text: "Connect your repo", at: nil),
            LaunchDemoCaption(text: "Pick a template", at: nil),
            LaunchDemoCaption(text: "Share the link", at: nil)
        ]
        let findings = analysis(kept: TimeSpan(start: 0, end: 30), beats: [8, 15, 22])
        var snapshot = blank()
        snapshot.editSettings.textOverlays = [TextOverlay(text: "Old", span: TimeSpan(start: 1, end: 3))]
        let report = try LaunchDemoRecipe(options: options).apply(to: &snapshot, take: take(), analysis: findings)

        #expect(report.beats == [8, 15, 22])
        #expect(report.text.map(\.role) == [.title, .tagline, .caption, .caption, .caption])
        // The title and tagline open the video and leave together; each caption lands on
        // an action.
        #expect(pairs(report.text.map(\.output)) == [[0.3, 2.7], [0.7, 2.7], [8, 10], [15, 17], [22, 24]])
        #expect(report.leftOut.isEmpty)

        // The old text is replaced.
        let overlays = snapshot.editSettings.textOverlays
        #expect(overlays.count == 5 && !overlays.contains { $0.text == "Old" })
        let title = try #require(overlays.first { $0.text == "Acme 2.0" })
        #expect(title.style == .title && title.animation == .rise)
        #expect(isClose(title.center.y, LaunchDemoRecipe.titleCenterAboveTagline.y))
        let caption = try #require(overlays.first { $0.text == "Pick a template" })
        #expect(caption.style == .caption && caption.animation == .pop)
        #expect(isClose(caption.span.start, 15) && isClose(caption.span.end, 17))
        #expect(report.changes.contains("Text: the title \"Acme 2.0\", a tagline, 3 captions, replacing what was there."))
    }

    @Test func textFollowsTheEdit() throws {
        // A 3 s pause is cut before the caption's moment: it shows at 10 s of the
        // recording, 2.6 s earlier in the video.
        var options = LaunchDemoOptions()
        options.captions = [LaunchDemoCaption(text: "Hit deploy", at: 10)]
        options.textAnimation = .typewriter
        let findings = analysis(kept: TimeSpan(start: 0, end: 30), dead: [TimeSpan(start: 4, end: 7)])
        var snapshot = blank()
        let report = try LaunchDemoRecipe(options: options).apply(to: &snapshot, take: take(), analysis: findings)
        let placed = try #require(report.text.first)
        #expect(pairs([placed.output]) == [[7.4, 9.4]])
        let overlay = try #require(snapshot.editSettings.textOverlays.first)
        #expect(isClose(overlay.span.start, 10, tolerance: 1e-6) && isClose(overlay.span.end, 12, tolerance: 1e-6))
        #expect(overlay.animation == .typewriter)
    }

    @Test func spreadsCaptionsWithoutOverlaps() {
        func captions(_ times: [TimeInterval?]) -> [LaunchDemoCaption] {
            times.map { LaunchDemoCaption(text: "Short", at: $0) }
        }
        let window = TimeSpan(start: 0, end: 10)
        // Evenly, without beats.
        let even = LaunchDemoRecipe.captionSpans(captions([nil, nil, nil]), window: window, beats: [], outputTime: { $0 })
        #expect(pairs(even) == [[0, 2], [3.333333, 5.333333], [6.666667, 8.666667]])
        // On beats that leave room in their share.
        let onBeats = LaunchDemoRecipe.captionSpans(captions([nil, nil]), window: TimeSpan(start: 0, end: 12), beats: [1, 4.5, 7.5], outputTime: { $0 })
        #expect(pairs(onBeats) == [[1, 3], [7.5, 9.5]])
        // Pinned close together: the later one waits.
        let pinned = LaunchDemoRecipe.captionSpans(captions([1, 1.5]), window: window, beats: [], outputTime: { $0 })
        #expect(pairs(pinned) == [[1, 3], [3.2, 5.2]])
        // Out of room at the end: left out.
        let crowded = LaunchDemoRecipe.captionSpans(captions([nil, nil, nil]), window: TimeSpan(start: 0, end: 5), beats: [], outputTime: { $0 })
        #expect(pairs(crowded) == [[0, 2], [2.2, 4.2], nil])
        #expect(LaunchDemoRecipe.captionSpans(captions([nil]), window: TimeSpan(start: 3, end: 3), beats: [], outputTime: { $0 }) == [nil])
    }

    @Test func textStaysUpLongEnoughToRead() {
        #expect(LaunchDemoRecipe.holdDuration("Hi") == 2)
        #expect(isClose(LaunchDemoRecipe.holdDuration(String(repeating: "a", count: 40)), 3.2))
        #expect(LaunchDemoRecipe.holdDuration(String(repeating: "a", count: 100)) == 4.5)
    }

    @Test func aLookWithoutABackgroundHasNoTiltIn() throws {
        var options = LaunchDemoOptions()
        options.look = "minimal"
        options.aspect = .square
        var snapshot = blank()
        snapshot.editSettings.cameraMoves = [CameraMove(kind: .float, span: TimeSpan(start: 5, end: 9))]
        let report = try LaunchDemoRecipe(options: options).apply(to: &snapshot, take: take(), analysis: analysis())
        #expect(report.changes.contains("Applied the Minimal look."))
        #expect(snapshot.editSettings.canvas.aspect == .square)
        #expect(snapshot.editSettings.cameraMoves.map(\.kind) == [.float])
        #expect(report.suggestions.contains { $0.hasPrefix("No 3D tilt-in") })

        options.look = "Nope"
        var other = blank()
        let unknown = failure { _ = try LaunchDemoRecipe(options: options).apply(to: &other, take: take(), analysis: analysis()) }
        #expect(unknown?.hasPrefix("No look is called \"Nope\"") == true)
    }

    @Test func runningItAgainDoesNotStack() throws {
        var options = LaunchDemoOptions()
        options.title = "Acme"
        var snapshot = blank()
        snapshot.editSettings.cameraMoves = [CameraMove(kind: .float, span: TimeSpan(start: 5, end: 9))]
        let recipe = LaunchDemoRecipe(options: options)
        _ = try recipe.apply(to: &snapshot, take: take(), analysis: analysis())
        let once = snapshot
        _ = try recipe.apply(to: &snapshot, take: take(), analysis: analysis())
        #expect(snapshot.editSettings.cameraMoves.map(\.kind).sorted { $0.rawValue < $1.rawValue } == [.float, .tiltIn])
        #expect(snapshot.editSettings.textOverlays.count == 1)
        let again = snapshot.editSettings.resolvedTimeline(sourceDuration: 30)
        #expect(again.segments.map(\.source) == once.editSettings.resolvedTimeline(sourceDuration: 30).segments.map(\.source))
        #expect(snapshot.keyframes.count == once.keyframes.count)
    }

    @Test func readsItsArguments() throws {
        let arguments = AgentArguments([
            "title": "  Acme  ",
            "tagline": "",
            "captions": ["One", ["text": "Two", "at": "0:12"], "  "],
            "aspect": "9:16",
            "pace": "punchy",
            "transition": "none",
            "text_animation": "typewriter",
            "tilt_in": false
        ])
        let options = try LaunchDemoOptions(arguments)
        #expect(options.title == "Acme" && options.tagline == nil)
        #expect(options.captions == [LaunchDemoCaption(text: "One", at: nil), LaunchDemoCaption(text: "Two", at: 12)])
        #expect(options.aspect == .portrait && options.pace == .punchy)
        #expect(options.transition == nil && options.textAnimation == .typewriter)
        #expect(!options.tiltIn && options.cropToApp)
        #expect(try LaunchDemoOptions(AgentArguments(["transition": "whip"])).transition == .whip)
        #expect(try LaunchDemoOptions(AgentArguments([:])) == LaunchDemoOptions())

        let shape = failure { _ = try LaunchDemoOptions(AgentArguments(["aspect": "round"])) }
        #expect(shape?.hasPrefix("aspect must be one of") == true)
        let number = failure { _ = try LaunchDemoOptions(AgentArguments(["captions": [5]])) }
        #expect(number == "captions[0] must be text, or {text, at}.")
        let untitled = failure { _ = try LaunchDemoOptions(AgentArguments(["captions": [["at": 3]]])) }
        #expect(untitled == "captions[0]: text is required.")
        let spin = failure { _ = try LaunchDemoOptions(AgentArguments(["transition": "spin"])) }
        #expect(spin?.hasPrefix("transition must be") == true)
    }

    @Test func reportsForAgents() throws {
        var options = LaunchDemoOptions()
        options.title = "Acme"
        let findings = analysis(dead: [TimeSpan(start: 10, end: 13)], beats: [8])
        var snapshot = blank()
        let report = try LaunchDemoRecipe(options: options).apply(to: &snapshot, take: take(), analysis: findings)
        let json = report.json
        #expect(json["cuts"]?.arrayValue?.first?["start"]?.doubleValue == 10.2)
        #expect(json["cropped_to"]?.isNull == true)
        let text = try #require(json["text"]?.arrayValue?.first)
        #expect(text["role"]?.stringValue == "title")
        #expect(text["text_id"]?.stringValue == snapshot.editSettings.textOverlays.first?.id.uuidString)
        #expect(text["output_start"]?.doubleValue == 0.3)
        // The beat at 8 s of the recording is 6 s into the video.
        #expect(json["beats_output"]?.arrayValue?.first?.doubleValue == 6)
        #expect(json["left_out"] == nil)
        #expect((json["changes"]?.arrayValue?.count ?? 0) >= 4)
    }
}
