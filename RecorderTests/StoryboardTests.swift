import CoreGraphics
import Foundation
import Testing
@testable import RecorderCore

private let frame = CGSize(width: 1920, height: 1080)

private func take(duration: TimeInterval = 40) -> AgentEditTake {
    let clicks = [5, 12, 20, 30].map { time in
        ClickEvent(timestamp: time, location: CGPoint(x: 1440, y: 270), button: .left)
    }
    return AgentEditTake(duration: duration, sourceSize: frame, clicks: clicks)
}

private func analysis(of take: AgentEditTake) -> TakeAnalysis {
    TakeAnalyzer().analyze(TakeAnalysisInput(
        duration: take.duration,
        frameSize: take.sourceSize,
        clicks: take.clicks,
        keystrokes: [],
        cursor: [],
        screen: nil,
        speech: nil
    ))
}

private func blank(duration: TimeInterval = 40) -> EditorSnapshot {
    var settings = ProjectEditSettings()
    settings.setTimeline(EditTimeline(sourceDuration: duration))
    return EditorSnapshot(keyframes: [], editSettings: settings)
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

/// A four-shot story: a hook pushing in, a step zooming onto its click (sped up), a pan
/// that floats in 3D, and a payoff pulling back.
private let story: JSONValue = [
    "shots": [
        [
            "start": 4, "end": 6.5,
            "camera": ["move": "push", "point": ["x": 0.3, "y": 0.4]],
            "text": "Ship demos in minutes"
        ],
        [
            "start": 11, "end": 14, "speed": 1.5,
            "camera": "zoom",
            "text": ["text": "Connect your repo", "position": "bottom"]
        ],
        [
            "start": 19, "end": 23,
            "camera": [
                "move": "pan",
                "rect": ["x": 0.1, "y": 0.1, "width": 0.3, "height": 0.3],
                "to": ["x": 0.6, "y": 0.6, "width": 0.3, "height": 0.3],
                "three_d": "float"
            ]
        ],
        [
            "start": 29, "end": 32, "payoff_at": 30.5,
            "camera": ["move": "pull", "scale": 2],
            "text": ["text": "Done", "style": "title"]
        ]
    ]
]

@Suite("Storyboards")
struct StoryboardTests {
    @Test func readsShotsInOrder() throws {
        let board = try Storyboard(AgentArguments(story), duration: 40)
        #expect(board.shots.map(\.role) == [.hook, .step, .step, .payoff])
        #expect(board.shots.map(\.speed) == [1, 1.5, 1, 1])
        #expect(board.shots.map(\.camera.move) == [.push, .zoom, .pan, .pull])
        #expect(board.shots[2].camera.threeD == .float)
        // Agents' top-left points are stored bottom-left.
        #expect(board.shots[0].camera.target.map { isClose($0.minY, 0.6) } == true)
        #expect(board.shots[0].text?.style == .title && board.shots[0].text?.animation == .rise)
        #expect(board.shots[1].text?.style == .caption && board.shots[1].text?.animation == .pop)
        #expect(board.transition == .zoomBlur)

        // A duration fits the shot by speed.
        let fitted = try Storyboard(AgentArguments(["shots": [["start": 0, "end": 6, "duration": 2]]]), duration: 40)
        #expect(isClose(fitted.shots[0].speed, 3))
    }

    @Test func explainsBadStoryboards() {
        func message(_ value: JSONValue) -> String? {
            failure { _ = try Storyboard(AgentArguments(value), duration: 40) }
        }
        #expect(message([:])?.hasPrefix("shots is required") == true)
        let overlapping: JSONValue = ["shots": [["start": 2, "end": 6], ["start": 5, "end": 8]]]
        #expect(message(overlapping)?.contains("Shots follow the recording in order") == true)
        #expect(message(["shots": [["start": 38, "end": 45]]])?.contains("outside the recording") == true)
        #expect(message(["shots": [["start": 2, "end": 2.2]]])?.contains("at least 0.4 s") == true)
        #expect(message(["shots": [["start": 2, "end": 5, "camera": "spin"]]])?.hasPrefix("shots[0]: camera must be one of") == true)
        #expect(message(["shots": [["start": 2, "end": 5, "camera": ["move": "pan"]]]])?.contains("A pan needs to") == true)
        #expect(message(["shots": [["start": 2, "end": 5, "payoff_at": 9]]])?.contains("payoff_at") == true)
    }

    @Test func buildsTheEditFromTheShots() throws {
        let source = take()
        let board = try Storyboard(AgentArguments(story), duration: 40)
        var snapshot = blank()
        let report = try StoryboardRecipe(storyboard: board).apply(to: &snapshot, take: source, analysis: analysis(of: source))
        let settings = snapshot.editSettings

        // Only the shots, each at its speed: 2.5 + 2 + 4 + 3 s.
        let timeline = settings.resolvedTimeline(sourceDuration: 40)
        #expect(timeline.segments.map(\.source) == board.shots.map(\.span))
        #expect(isClose(timeline.outputDuration, 11.5, tolerance: 1e-6))
        #expect(isClose(report.outputDuration, 11.5, tolerance: 1e-6))
        #expect(report.shots.map { ($0.output.start * 100).rounded() / 100 } == [0, 2.5, 4.5, 8.5])

        let zooms = snapshot.keyframes
        try #require(zooms.count == 6)
        // The hook pushes in over the whole shot, settling after it ends.
        #expect(isClose(zooms[0].startTime, 4) && isClose(zooms[0].peakTime, 6.5) && isClose(zooms[0].endTime, 7.1))
        #expect(isClose(zooms[0].scale, StoryboardRecipe.pushScale))
        // Aimed as close to the point as the view allows while staying in the picture.
        func within(_ value: CGFloat, scale: CGFloat) -> CGFloat {
            let half = 0.5 / scale
            return min(max(value, half), 1 - half)
        }
        #expect(isClose(zooms[0].centerX, within(0.3, scale: StoryboardRecipe.pushScale)) && isClose(zooms[0].centerY, 0.6))
        // The step zooms onto its click as it starts (0.5 s of video at 1.5×).
        #expect(isClose(zooms[1].startTime, 11) && isClose(zooms[1].peakTime, 11.75))
        let preset = ZoomPreset.demo.settings.zoomScale
        #expect(isClose(zooms[1].scale, preset))
        #expect(isClose(zooms[1].centerX, within(0.75, scale: preset)) && isClose(zooms[1].centerY, within(0.25, scale: preset)))
        // The pan: two zooms back to back, at the same scale.
        #expect(ZoomKeyframeEditor.areChained(zooms[2], zooms[3]))
        #expect(isClose(zooms[2].scale, zooms[3].scale))
        // The payoff starts close and pulls back to the whole picture.
        #expect(ZoomKeyframeEditor.areChained(zooms[4], zooms[5]))
        #expect(isClose(zooms[4].scale, 2) && isClose(zooms[4].peakTime, 29) && isClose(zooms[5].scale, 1))
        #expect(isClose(zooms[5].peakTime, 32))
        #expect(settings.cameraMoves.map(\.kind) == [.float])
        #expect(settings.cameraMoves.first?.span == TimeSpan(start: 19, end: 23))

        // Kinetic type, timed in the video.
        #expect(settings.textOverlays.map(\.text) == ["Ship demos in minutes", "Connect your repo", "Done"])
        let hookText = try #require(report.shots[0].textOutput)
        #expect(isClose(hookText.start, 0.15) && isClose(hookText.end, 2.15))
        #expect(isClose(settings.textOverlays[1].center.y, 0.86))
        // The caption needs 2 s; the sped-up shot leaves 1.85.
        #expect(report.shots[1].warnings.first?.hasPrefix("Its text needs 2.0 s") == true)

        // A hook in the first 2 s, and something new at least every 5 s.
        #expect(report.hookOK)
        #expect(report.longestWait.map { $0.duration <= 5 } == true)
        #expect(settings.cutTransition == CutTransition(style: .zoomBlur, duration: StoryboardRecipe.transitionDuration))
        #expect(settings.exportStyle.motionBlurEnabled && settings.exportStyle.springCameraEnabled)
        #expect(report.json["hook"]?["ok"]?.boolValue == true)
        #expect(report.json["shots"]?.arrayValue?.count == 4)
    }

    @Test func flagsAWeakHookAndADraggingShot() throws {
        let source = take()
        let board = try Storyboard(AgentArguments(["shots": [["start": 6, "end": 26]]]), duration: 40)
        var snapshot = blank()
        let report = try StoryboardRecipe(storyboard: board).apply(to: &snapshot, take: source, analysis: analysis(of: source))
        #expect(!report.hookOK)
        #expect(report.warnings.contains { $0.hasPrefix("No text in the first 2 s") })
        #expect(report.warnings.contains { $0.hasPrefix("The opening shot runs 20.0 s") })
        #expect(report.warnings.contains { $0.hasPrefix("Nothing new lands from") })
        #expect(report.warnings.contains { $0.hasPrefix("shots[0]: It runs 20.0 s") })
    }

    @Test func autoKeepsTheClickZoomsInItsShot() throws {
        let source = take()
        let board = try Storyboard(AgentArguments(["shots": [["start": 4, "end": 13, "camera": "auto"]]]), duration: 40)
        var snapshot = blank()
        _ = try StoryboardRecipe(storyboard: board).apply(to: &snapshot, take: source, analysis: analysis(of: source))
        // Clicks at 5 and 12 are in the shot; 20 and 30 aren't.
        #expect(snapshot.keyframes.count == 2)
        #expect(snapshot.keyframes.allSatisfy { $0.peakTime >= 4 && $0.peakTime <= 13 })
    }
}
