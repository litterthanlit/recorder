import CoreGraphics
import Foundation
import Testing
@testable import RecorderCore

@Suite("AutoZoomGenerator")
struct AutoZoomGeneratorTests {
    @Test func mergesNearbyClicks() {
        let generator = AutoZoomGenerator(frameWidth: 1920, frameHeight: 1080)
        let events = [
            ClickEvent(timestamp: 1.0, location: CGPoint(x: 400, y: 400), button: .left),
            ClickEvent(timestamp: 1.3, location: CGPoint(x: 420, y: 410), button: .left)
        ]

        let keyframes = generator.generate(from: events)
        #expect(keyframes.count == 1)
        #expect(abs(keyframes[0].peakTime - 1.15) < 0.01)
    }

    @Test func chainsOverlappingKeyframes() {
        let generator = AutoZoomGenerator(frameWidth: 1920, frameHeight: 1080)
        let events = [
            ClickEvent(timestamp: 1.0, location: CGPoint(x: 300, y: 300), button: .left),
            ClickEvent(timestamp: 2.5, location: CGPoint(x: 1500, y: 800), button: .left)
        ]

        let keyframes = generator.generate(from: events)
        #expect(keyframes.count == 2)
        #expect(keyframes[1].startTime >= keyframes[0].endTime)
    }

    @Test func frequentClicksDoNotDriftLater() {
        let generator = AutoZoomGenerator(
            settings: AutoZoomSettings(zoomScale: 1.6, holdDuration: 1.3),
            frameWidth: 1920,
            frameHeight: 1080
        )
        let clickTimes: [TimeInterval] = [1, 2, 3, 4, 5, 6, 7, 8]
        let events = clickTimes.enumerated().map { index, time in
            ClickEvent(
                timestamp: time,
                location: CGPoint(x: index.isMultiple(of: 2) ? 300 : 1500, y: 500),
                button: .left
            )
        }

        let keyframes = generator.generate(from: events)
        #expect(keyframes.count == clickTimes.count)
        for (keyframe, clickTime) in zip(keyframes, clickTimes) {
            #expect(abs(keyframe.peakTime - clickTime) < 0.001)
        }
        for index in 1..<keyframes.count {
            #expect(keyframes[index].startTime >= keyframes[index - 1].endTime - 0.0001)
        }
    }

    @Test func emptyEventsProduceNoKeyframes() {
        let generator = AutoZoomGenerator(frameWidth: 1920, frameHeight: 1080)
        #expect(generator.generate(from: []).isEmpty)
    }
}

@Suite("ZoomInterpolator")
struct ZoomInterpolatorTests {
    @Test func fullFrameOutsideKeyframes() {
        let keyframes = [
            ZoomKeyframe(
                startTime: 2,
                peakTime: 2.35,
                endTime: 3,
                center: CGPoint(x: 0.5, y: 0.5),
                scale: 1.8
            )
        ]
        let interpolator = ZoomInterpolator(keyframes: keyframes)
        let rect = interpolator.cropRect(at: 0.5)
        #expect(rect.width == 1)
        #expect(rect.height == 1)
    }

    @Test func zoomsAtPeak() {
        let keyframes = [
            ZoomKeyframe(
                startTime: 1,
                peakTime: 1.35,
                endTime: 2,
                center: CGPoint(x: 0.5, y: 0.5),
                scale: 2
            )
        ]
        let interpolator = ZoomInterpolator(keyframes: keyframes)
        let rect = interpolator.cropRect(at: 1.35)
        #expect(abs(rect.width - 0.5) < 0.01)
        #expect(abs(rect.height - 0.5) < 0.01)
    }

    @Test func easeInOutUsesFullFrameAtStart() {
        let keyframes = [
            ZoomKeyframe(
                startTime: 1,
                peakTime: 1.35,
                endTime: 2,
                center: CGPoint(x: 0.5, y: 0.5),
                scale: 2
            )
        ]
        let interpolator = ZoomInterpolator(keyframes: keyframes)
        let rect = interpolator.cropRect(at: 1)
        #expect(rect.width == 1)
    }

    @Test func springOvershootsThenSettlesAtPeak() {
        let keyframes = [
            ZoomKeyframe(
                startTime: 1,
                peakTime: 1.35,
                endTime: 2,
                center: CGPoint(x: 0.5, y: 0.5),
                scale: 2
            )
        ]
        let interpolator = ZoomInterpolator(
            keyframes: keyframes,
            springEnabled: true,
            springSettings: .punch
        )

        #expect(abs(interpolator.scale(at: 1) - 1) < 0.02)

        var didOvershoot = false
        var sample = 1.02
        while sample < 1.35 {
            if interpolator.scale(at: sample) > 2.01 {
                didOvershoot = true
                break
            }
            sample += 0.01
        }
        #expect(didOvershoot)
        #expect(abs(interpolator.scale(at: 1.35) - 2) < 0.04)
    }

    @Test func chainedKeyframesPanWithoutReturningToFullFrame() {
        let keyframes = [
            ZoomKeyframe(startTime: 0, peakTime: 0.35, endTime: 1, center: CGPoint(x: 0.3, y: 0.5), scale: 2),
            ZoomKeyframe(startTime: 1, peakTime: 1.35, endTime: 2, center: CGPoint(x: 0.7, y: 0.5), scale: 2)
        ]
        let interpolator = ZoomInterpolator(keyframes: keyframes)

        var sample = 0.35
        while sample <= 1.35 {
            #expect(interpolator.cropRect(at: sample).width < 0.51)
            sample += 0.05
        }
        let midPan = interpolator.cropRect(at: 1.175)
        #expect(midPan.x + midPan.width / 2 > 0.3)
        #expect(midPan.x + midPan.width / 2 < 0.7)
    }
}

@Suite("ZoomKeyframeEditor")
struct ZoomKeyframeEditorTests {
    @Test func createsManualKeyframeFromRect() {
        let keyframe = ZoomKeyframeEditor.makeManualKeyframe(
            at: 2,
            normalizedRect: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
            duration: 10
        )
        #expect(keyframe.source == .manual)
        #expect(keyframe.peakTime == 2)
        #expect(keyframe.scale > 1)
    }

    @Test func selectionNearTopOfPreviewMapsToTopOfSource() {
        // 16:10 source inside a 16:9 preview with padding -> pillarboxed content.
        let canvas = CGSize(width: 1600, height: 900)
        let frame = ZoomKeyframeEditor.fittedContentFrame(contentAspect: 1.6, in: canvas, padding: 96)
        #expect(abs(frame.height - 708) < 0.5)
        #expect(abs(frame.midX - 800) < 0.5)

        // Drag across the top-left quarter of the visible video (view y grows downward).
        let selection = CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height / 2)
        let rect = ZoomKeyframeEditor.sourceRect(
            forSelection: selection,
            contentFrame: frame,
            visibleCrop: .fullFrame
        )
        #expect(rect != nil)
        #expect(abs(rect!.minX - 0) < 0.001)
        #expect(abs(rect!.minY - 0.5) < 0.001)
        #expect(abs(rect!.width - 0.5) < 0.001)
        #expect(abs(rect!.height - 0.5) < 0.001)
    }

    @Test func selectionMapsThroughCurrentZoom() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let visible = NormalizedRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        let rect = ZoomKeyframeEditor.sourceRect(
            forSelection: CGRect(x: 0, y: 50, width: 50, height: 50),
            contentFrame: frame,
            visibleCrop: visible
        )
        #expect(rect != nil)
        #expect(abs(rect!.minX - 0.5) < 0.001)
        #expect(abs(rect!.minY - 0.5) < 0.001)
        #expect(abs(rect!.width - 0.25) < 0.001)
    }

    @Test func selectionOutsideVideoIsIgnored() {
        let frame = CGRect(x: 100, y: 0, width: 100, height: 100)
        let rect = ZoomKeyframeEditor.sourceRect(
            forSelection: CGRect(x: 0, y: 0, width: 50, height: 50),
            contentFrame: frame,
            visibleCrop: .fullFrame
        )
        #expect(rect == nil)
    }

    @Test func chainsOverlapsAfterManualAdd() {
        var keyframes = [
            ZoomKeyframe(startTime: 1, peakTime: 1.5, endTime: 3, center: CGPoint(x: 0.5, y: 0.5), scale: 1.8),
            ZoomKeyframe(startTime: 2.5, peakTime: 3, endTime: 4, center: CGPoint(x: 0.2, y: 0.2), scale: 2, source: .manual)
        ]
        ZoomKeyframeEditor.resolveOverlaps(&keyframes)
        #expect(keyframes[1].startTime >= keyframes[0].endTime)
    }
}

@Suite("CursorPathSmoother")
struct CursorPathSmootherTests {
    @Test func interpolatesBetweenSamples() {
        let smoother = CursorPathSmoother()
        let events = [
            CursorEvent(timestamp: 0, location: CGPoint(x: 0, y: 0)),
            CursorEvent(timestamp: 1, location: CGPoint(x: 100, y: 100))
        ]
        let point = smoother.location(at: 0.5, in: events)
        #expect(point != nil)
        #expect(point!.x > 0)
        #expect(point!.x < 100)
    }

    @Test func smoothReducesJitter() {
        let smoother = CursorPathSmoother()
        let events = [
            CursorEvent(timestamp: 0, location: CGPoint(x: 0, y: 0)),
            CursorEvent(timestamp: 0.01, location: CGPoint(x: 50, y: 0)),
            CursorEvent(timestamp: 0.02, location: CGPoint(x: 0, y: 0))
        ]
        let smoothed = smoother.smooth(events)
        #expect(smoothed[1].location.x < 50)
    }
}

@Suite("SpringCamera")
struct SpringCameraTests {
    @Test func underdampedStepOvershootsThenSettles() {
        var maximum: CGFloat = 0
        for step in 0...100 {
            let value = SpringCamera.underdampedStep(
                t: CGFloat(step) / 100,
                zeta: 0.62,
                omega: 9
            )
            maximum = max(maximum, value)
        }
        #expect(maximum > 1.02)
        #expect(abs(SpringCamera.underdampedStep(t: 0, zeta: 0.62, omega: 9)) < 0.001)
        #expect(abs(SpringCamera.underdampedStep(t: 1, zeta: 0.62, omega: 9) - 1) < 0.02)
    }
}

@Suite("ClickRippleEvaluator")
struct ClickRippleEvaluatorTests {
    @Test func progressIsZeroAtClickAndOneAtDuration() {
        let evaluator = ClickRippleEvaluator(duration: 0.4, secondRingDelay: 0.08)
        let click = ClickEvent(timestamp: 1.0, location: CGPoint(x: 100, y: 80), button: .left)

        #expect(evaluator.progress(at: 1.0, click: click) == 0)
        let atEnd = evaluator.progress(at: 1.0 + 0.4, click: click)
        #expect(atEnd != nil)
        #expect(abs((atEnd ?? 0) - 1) < 1e-9)
        #expect(evaluator.progress(at: 1.0 + 0.4 + 0.01, click: click) == nil)
        #expect(evaluator.progress(at: 0.5, click: click) == nil)
    }

    @Test func idleWhenNoActiveRipple() {
        let evaluator = ClickRippleEvaluator(duration: 0.4, secondRingDelay: 0.08)
        let click = ClickEvent(timestamp: 2.0, location: CGPoint(x: 10, y: 10), button: .left)
        #expect(evaluator.ripples(at: 0.2, clicks: [click]).isEmpty)
    }
}

@Suite("ConstantFrameRateTimeline")
struct ConstantFrameRateTimelineTests {
    @Test func producesEvenlySpacedFramesForTheWholeDuration() {
        let timeline = ConstantFrameRateTimeline(frameRate: 60, duration: 2, sourceStart: 5)
        #expect(timeline.frameCount == 120)
        #expect(timeline.sourceTime(forFrame: 0) == 5)
        #expect(abs(timeline.outputTime(forFrame: 119) - 119.0 / 60.0) < 1e-9)
    }

    @Test func coversPartialLastFrame() {
        let timeline = ConstantFrameRateTimeline(frameRate: 30, duration: 1.01, sourceStart: 0)
        #expect(timeline.frameCount == 31)
        #expect(ConstantFrameRateTimeline(frameRate: 30, duration: 0, sourceStart: 0).frameCount == 0)
    }

    @Test func holdsLastFrameThroughStillStretches() {
        // Screen changed at 0, 0.1, then nothing until 1.0 (a still page), then 1.02.
        let sourceTimes: [TimeInterval] = [0, 0.1, 1.0, 1.02]
        let timeline = ConstantFrameRateTimeline(frameRate: 10, duration: 1.5, sourceStart: 0)
        let held = timeline.heldSourceFrameIndices(sourceTimes: sourceTimes)

        #expect(held.count == 15)
        #expect(held[0] == 0)
        // Every output frame from 0.1 s up to 0.9 s still exists and shows frame 1.
        #expect(held[1...9].allSatisfy { $0 == 1 })
        #expect(held[10] == 2)
        // After the last change the final frame is held to the end instead of stopping.
        #expect(held[11...].allSatisfy { $0 == 3 })
    }

    @Test func showsFirstFrameWhenTrimStartsBeforeIt() {
        let timeline = ConstantFrameRateTimeline(frameRate: 10, duration: 0.5, sourceStart: 2)
        let held = timeline.heldSourceFrameIndices(sourceTimes: [2.25, 2.4])
        #expect(held == [0, 0, 0, 0, 1])
    }

    @Test func frameAtExactOutputTimeIsUsedDespiteRounding() {
        let timeline = ConstantFrameRateTimeline(frameRate: 60, duration: 1, sourceStart: 0)
        // 1/60 computed a different way lands a hair after the output time.
        let held = timeline.heldSourceFrameIndices(sourceTimes: [0, 1.0 / 60.0 + 1e-7])
        #expect(held[1] == 1)
    }
}

@Suite("CompositionTimeMap")
struct CompositionTimeMapTests {
    @Test func oneClipMapsCompositionTimeToSourceTime() {
        let map = CompositionFactory.singleClip(
            sourcePath: "/tmp/video.mov",
            sourceIn: 2,
            sourceOut: 10
        )

        let start = map.resolve(compositionTime: 0)
        #expect(start?.sourceTime == 2)

        let middle = map.resolve(compositionTime: 3)
        #expect(middle?.sourceTime == 5)
        #expect(map.duration == 8)
    }

    @Test func outsideClipReturnsNil() {
        let map = CompositionFactory.singleClip(
            sourcePath: "/tmp/video.mov",
            sourceIn: 0,
            sourceOut: 4
        )
        #expect(map.resolve(compositionTime: 4.2) == nil)
    }
}
