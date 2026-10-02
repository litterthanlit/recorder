import CoreGraphics
import Foundation
import Testing
@testable import RecorderCore

@Suite("Text motion")
struct TextMotionTests {
    private let span = TimeSpan(start: 1, end: 4)

    @Test func fadeIsUnchanged() {
        for step in 0...50 {
            let time = Double(step) / 10
            let state = TextMotion.state(.fade, span: span, characters: 10, at: time)
            #expect(state.opacity == TimelineItemFade.opacity(at: time, span: span, fade: TextOverlay.fadeDuration))
            #expect(state.rise == 0 && state.scale == 1 && state.blur == 0 && state.revealed == nil)
        }
    }

    @Test func nothingShowsOutsideItsTime() {
        for animation in TextAnimation.allCases {
            #expect(!TextMotion.state(animation, span: span, characters: 10, at: 0.5).isVisible)
            #expect(!TextMotion.state(animation, span: span, characters: 10, at: 4.5).isVisible)
            #expect(TextMotion.state(animation, span: span, characters: 10, at: 2.5).isVisible)
        }
    }

    @Test func riseComesUpIntoPlaceAndDriftsAway() {
        let start = TextMotion.state(.rise, span: span, characters: 10, at: 1)
        #expect(isClose(start.rise, -28) && start.opacity == 0)
        let early = TextMotion.state(.rise, span: span, characters: 10, at: 1.1)
        #expect(early.rise < 0 && early.opacity > 0)
        let settled = TextMotion.state(.rise, span: span, characters: 10, at: 2.5)
        #expect(isClose(settled.rise, 0) && isClose(settled.opacity, 1))
        let leaving = TextMotion.state(.rise, span: span, characters: 10, at: 3.9)
        #expect(leaving.rise > 0 && leaving.opacity < 1)
    }

    @Test func popOvershootsThenSettles() {
        let scales = (0...25).map { TextMotion.state(.pop, span: TimeSpan(start: 0, end: 3), characters: 5, at: Double($0) / 50).scale }
        #expect(scales.first.map { $0 < 0.9 } == true)
        #expect(scales.contains { $0 > 1.005 })
        #expect(isClose(TextMotion.state(.pop, span: TimeSpan(start: 0, end: 3), characters: 5, at: 1.5).scale, 1, tolerance: 0.01))
    }

    @Test func blurComesIntoFocus() {
        let early = TextMotion.state(.blur, span: TimeSpan(start: 0, end: 3), characters: 5, at: 0.05)
        #expect(early.blur > 10)
        let focused = TextMotion.state(.blur, span: TimeSpan(start: 0, end: 3), characters: 5, at: 1.5)
        #expect(isClose(focused.blur, 0) && isClose(focused.scale, 1))
    }

    @Test func typewriterTypesOnAndFinishesInTime() {
        let typing = TimeSpan(start: 0, end: 4)
        #expect(TextMotion.state(.typewriter, span: typing, characters: 20, at: 0.5).revealed == 15)
        #expect(TextMotion.state(.typewriter, span: typing, characters: 20, at: 1).revealed == 20)
        #expect(TextMotion.state(.typewriter, span: typing, characters: 20, at: 0.5).opacity == 1)
        // Long text types faster: done by 60% of its time on screen.
        #expect(TextMotion.state(.typewriter, span: typing, characters: 200, at: 2.41).revealed == 200)
        #expect(!TextMotion.state(.typewriter, span: typing, characters: 0, at: 1).isVisible)
    }

    @Test func animationIsSavedAndReadTolerantly() throws {
        let overlay = TextOverlay(text: "Hi", span: TimeSpan(start: 0, end: 1), animation: .pop)
        let decoded = try JSONDecoder().decode(TextOverlay.self, from: JSONEncoder().encode(overlay))
        #expect(decoded.animation == .pop)
        #expect(decoded == overlay)
        let unknown = #"{ "text": "Hi", "span": { "start": 0, "end": 1 }, "animation": "wobble" }"#
        #expect(try JSONDecoder().decode(TextOverlay.self, from: Data(unknown.utf8)).animation == .fade)
        let legacy = #"{ "text": "Hi", "span": { "start": 0, "end": 1 } }"#
        #expect(try JSONDecoder().decode(TextOverlay.self, from: Data(legacy.utf8)).animation == .fade)
    }

    @Test func agentsPickTheAnimation() throws {
        var settings = ProjectEditSettings()
        settings.setTimeline(EditTimeline(sourceDuration: 20))
        var snapshot = EditorSnapshot(keyframes: [], editSettings: settings)
        let take = AgentEditTake(duration: 20, sourceSize: CGSize(width: 1920, height: 1080))
        _ = try AgentEdits.editText(
            &snapshot,
            operations: [AgentArguments(["op": "add", "text": "Launch day", "start": 1, "animation": "pop"])],
            take: take,
            timeBase: .source
        )
        let overlay = try #require(snapshot.editSettings.textOverlays.first)
        #expect(overlay.animation == .pop)
        _ = try AgentEdits.editText(
            &snapshot,
            operations: [AgentArguments(["op": "update", "text_id": .string(overlay.id.uuidString), "animation": "typewriter"])],
            take: take,
            timeBase: .source
        )
        #expect(snapshot.editSettings.textOverlays.first?.animation == .typewriter)
        #expect(TakeDescription.textJSON(snapshot.editSettings.textOverlays[0])["animation"]?.stringValue == "typewriter")
    }
}
