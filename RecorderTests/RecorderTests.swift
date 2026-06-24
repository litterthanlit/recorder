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
