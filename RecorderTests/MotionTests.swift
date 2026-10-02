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

@Suite("Cut transitions and audio")
struct CutMotionTests {
    /// 0–4, then a cut to 6–10, then a split (no cut) to 10–12.
    private let cutTimeline = EditTimeline(
        segments: [
            EditSegment(source: TimeSpan(start: 0, end: 4)),
            EditSegment(source: TimeSpan(start: 6, end: 10)),
            EditSegment(source: TimeSpan(start: 10, end: 12))
        ],
        sourceDuration: 12
    )

    @Test func transitionsPeakAtCuts() {
        #expect(CutTransitions.cutTimes(in: cutTimeline) == [4])
        let atCut = CutTransitions.state(atOutput: 4, cuts: [4], duration: 0.4)
        #expect(atCut.map { isClose($0.progress, 0) && isClose($0.intensity, 1) } == true)
        let before = CutTransitions.state(atOutput: 3.9, cuts: [4], duration: 0.4)
        #expect(before.map { isClose($0.progress, -0.5, tolerance: 1e-9) && isClose($0.intensity, 0.5, tolerance: 1e-9) } == true)
        #expect(CutTransitions.state(atOutput: 4.25, cuts: [4], duration: 0.4) == nil)
        #expect(CutTransitions.state(atOutput: 4, cuts: [], duration: 0.4) == nil)
    }

    @Test func transitionsReadTolerantly() throws {
        let odd = #"{ "style": "spin", "duration": 5 }"#
        let transition = try JSONDecoder().decode(CutTransition.self, from: Data(odd.utf8))
        #expect(transition.style == .zoomBlur)
        #expect(transition.duration == CutTransition.durationRange.upperBound)

        var settings = ProjectEditSettings()
        settings.cutTransition = CutTransition(style: .whip, duration: 0.3)
        settings.audio.cutFades = true
        settings.audio.muteSpedUp = true
        let decoded = try JSONDecoder().decode(ProjectEditSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }

    @Test func audioFadesAtCuts() {
        let ramps = AudioEnvelope.ramps(for: cutTimeline, audio: AudioMixSettings(cutFades: true))
        #expect(ramps.count == 2)
        #expect(isClose(ramps[0].start, 3.96, tolerance: 1e-9) && ramps[0].from == 1 && ramps[0].to == 0)
        #expect(isClose(ramps[1].start, 4, tolerance: 1e-9) && ramps[1].from == 0 && ramps[1].to == 1)
        #expect(AudioEnvelope.initialGain(ramps) == 1)
        #expect(AudioEnvelope.ramps(for: cutTimeline, audio: AudioMixSettings()).isEmpty)
    }

    @Test func fastPartsGoQuiet() {
        let timeline = EditTimeline(
            segments: [
                EditSegment(source: TimeSpan(start: 0, end: 4)),
                EditSegment(source: TimeSpan(start: 4, end: 12), speed: 4),
                EditSegment(source: TimeSpan(start: 12, end: 16))
            ],
            sourceDuration: 16
        )
        #expect(AudioEnvelope.mutedSpans(in: timeline) == [TimeSpan(start: 4, end: 6)])
        let ramps = AudioEnvelope.ramps(for: timeline, audio: AudioMixSettings(muteSpedUp: true))
        #expect(ramps.count == 2)
        #expect(isClose(ramps[0].start, 4) && isClose(ramps[0].duration, AudioEnvelope.muteRamp, tolerance: 1e-9) && ramps[0].to == 0)
        #expect(isClose(ramps[1].start + ramps[1].duration, 6, tolerance: 1e-9) && ramps[1].to == 1)
    }

    @Test func newTakesUseNoOptionalEffects() {
        var settings = ProjectEditSettings()
        settings.setTimeline(EditTimeline(sourceDuration: 10))
        #expect(RenderFeatures(settings: settings).isEmpty)
        #expect(RenderFeatures(settings: ProjectEditSettings()).isEmpty)

        settings.cutTransition = CutTransition()
        settings.textOverlays = [TextOverlay(text: "Hi", span: TimeSpan(start: 0, end: 1), animation: .rise)]
        settings.audio.cutFades = true
        var timeline = settings.resolvedTimeline(sourceDuration: 10)
        timeline.speedRamp = SpeedRamp.defaultRamp
        settings.setTimeline(timeline)
        let features = RenderFeatures(settings: settings)
        #expect(features.cutTransitions && features.animatedText && features.audioEnvelope && features.speedRamps)
        #expect(!features.cameraMoves)
    }

    @Test func agentsSetMotionThroughStyle() throws {
        var settings = ProjectEditSettings()
        settings.setTimeline(EditTimeline(sourceDuration: 20))
        var snapshot = EditorSnapshot(keyframes: [], editSettings: settings)
        let take = AgentEditTake(duration: 20, sourceSize: CGSize(width: 1920, height: 1080))
        let notes = try AgentEdits.setStyle(
            &snapshot,
            arguments: AgentArguments([
                "cut_transition": "whip",
                "cut_transition_duration": 0.3,
                "smooth_speed_changes": true,
                "cut_audio_fades": true,
                "mute_sped_up_audio": true
            ]),
            take: take
        )
        #expect(notes.count == 5)
        #expect(snapshot.editSettings.cutTransition == CutTransition(style: .whip, duration: 0.3))
        #expect(snapshot.editSettings.timeline?.speedRamp == SpeedRamp.defaultRamp)
        #expect(snapshot.editSettings.audio.cutFades && snapshot.editSettings.audio.muteSpedUp)

        let timeline = snapshot.editSettings.resolvedTimeline(sourceDuration: 20)
        let motion = TakeDescription.motionJSON(snapshot.editSettings, timeline: timeline)
        #expect(motion["cut_transition"]?["style"]?.stringValue == "whip")
        #expect(motion["smooth_speed_changes"]?.boolValue == true)

        _ = try AgentEdits.setStyle(&snapshot, arguments: AgentArguments(["cut_transition": "none"]), take: take)
        #expect(snapshot.editSettings.cutTransition == nil)
        let message: String?
        do {
            _ = try AgentEdits.setStyle(&snapshot, arguments: AgentArguments(["cut_transition": "spin"]), take: take)
            message = nil
        } catch let error as AgentToolError {
            message = error.message
        }
        #expect(message?.hasPrefix("cut_transition must be") == true)

        // Resetting the edit keeps smooth speed changes.
        _ = try AgentEdits.editTimeline(&snapshot, operations: [AgentArguments(["op": "reset"])], take: take, timeBase: .source)
        #expect(snapshot.editSettings.timeline?.speedRamp == SpeedRamp.defaultRamp)
    }
}
