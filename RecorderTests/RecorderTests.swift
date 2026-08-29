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
        #expect(evaluator.progress(at: 1.4, click: click) == 1)
        #expect(evaluator.progress(at: 1.41, click: click) == nil)
        #expect(evaluator.progress(at: 0.5, click: click) == nil)
    }

    @Test func idleWhenNoActiveRipple() {
        let evaluator = ClickRippleEvaluator(duration: 0.4, secondRingDelay: 0.08)
        let click = ClickEvent(timestamp: 2.0, location: CGPoint(x: 10, y: 10), button: .left)
        #expect(evaluator.ripples(at: 0.2, clicks: [click]).isEmpty)
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
