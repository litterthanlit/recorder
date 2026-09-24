import AVFoundation
import CoreGraphics
import CoreMedia
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

    private let resizable = ZoomKeyframe(
        startTime: 2, peakTime: 2.5, endTime: 4, center: CGPoint(x: 0.5, y: 0.5), scale: 2
    )

    @Test func resizingStartKeepsEndAndPeak() {
        let earlier = ZoomKeyframeEditor.resizeKeyframeStart(resizable, to: 1.2, duration: 10)
        #expect(abs(earlier.startTime - 1.2) < 1e-9)
        #expect(abs(earlier.peakTime - 2.5) < 1e-9)
        #expect(abs(earlier.endTime - 4) < 1e-9)
    }

    @Test func resizingStartPastTheEndKeepsMinimumSpan() {
        let squeezed = ZoomKeyframeEditor.resizeKeyframeStart(resizable, to: 9, duration: 10)
        #expect(abs(squeezed.endTime - 4) < 1e-9)
        #expect(abs(squeezed.endTime - squeezed.startTime - ZoomKeyframeEditor.minimumSpan) < 1e-9)
        #expect(squeezed.peakTime >= squeezed.startTime && squeezed.peakTime <= squeezed.endTime)
    }

    @Test func resizingStartStopsAtZero() {
        let clamped = ZoomKeyframeEditor.resizeKeyframeStart(resizable, to: -3, duration: 10)
        #expect(abs(clamped.startTime) < 1e-9)
    }

    @Test func resizingEndStaysInsideTheRecording() {
        let longer = ZoomKeyframeEditor.resizeKeyframeEnd(resizable, to: 6, duration: 10)
        #expect(abs(longer.endTime - 6) < 1e-9)
        #expect(abs(longer.startTime - 2) < 1e-9)

        let clamped = ZoomKeyframeEditor.resizeKeyframeEnd(resizable, to: 50, duration: 10)
        #expect(abs(clamped.endTime - 10) < 1e-9)
    }

    @Test func resizingEndBeforePeakPullsPeakIn() {
        let shorter = ZoomKeyframeEditor.resizeKeyframeEnd(resizable, to: 2.3, duration: 10)
        #expect(abs(shorter.endTime - 2.3) < 1e-9)
        #expect(shorter.peakTime <= shorter.endTime)
        #expect(shorter.peakTime >= shorter.startTime)
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

    @Test func binarySearchMatchesLinearScan() {
        // Deterministic pseudo-random path with uneven sample spacing.
        var seed: UInt64 = 42
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        var time = 0.0
        let events: [CursorEvent] = (0..<500).map { _ in
            time += 0.001 + next() * 0.05
            return CursorEvent(timestamp: time, location: CGPoint(x: next() * 3000, y: next() * 2000))
        }

        func reference(_ t: TimeInterval) -> CGPoint {
            if t <= events[0].timestamp { return events[0].location }
            if t >= events[events.count - 1].timestamp { return events[events.count - 1].location }
            for index in 0..<(events.count - 1) where t >= events[index].timestamp && t < events[index + 1].timestamp {
                let current = events[index]
                let following = events[index + 1]
                let progress = CGFloat((t - current.timestamp) / (following.timestamp - current.timestamp))
                return CGPoint(
                    x: current.location.x + (following.location.x - current.location.x) * progress,
                    y: current.location.y + (following.location.y - current.location.y) * progress
                )
            }
            return events[events.count - 1].location
        }

        let smoother = CursorPathSmoother()
        var sample = -0.5
        while sample < time + 0.5 {
            let expected = reference(sample)
            let actual = smoother.location(at: sample, in: events)
            #expect(actual != nil)
            #expect(abs(actual!.x - expected.x) < 1e-6)
            #expect(abs(actual!.y - expected.y) < 1e-6)
            sample += 0.0137
        }
        // Exactly on a sample.
        #expect(smoother.location(at: events[250].timestamp, in: events) == events[250].location)
        #expect(smoother.location(at: 1, in: []) == nil)
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

@Suite("MediaTiming")
struct MediaTimingTests {
    /// 1024 mono float samples at 48 kHz, described by one timing entry (as capture does).
    private func makeAudioBuffer(presentationTime: CMTime) -> CMSampleBuffer? {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &description,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        )

        let byteCount = 1024 * 4
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        )

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleSize = 4
        var buffer: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: 1024,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &buffer
        )
        return buffer
    }

    @Test func retimingShiftsTimeButKeepsPerSampleDuration() throws {
        let original = try #require(makeAudioBuffer(presentationTime: CMTime(value: 480_000, timescale: 48_000)))
        let originalDuration = CMSampleBufferGetDuration(original)

        let shifted = try #require(original.retimed(by: CMTime(seconds: -9.5, preferredTimescale: 48_000)))

        #expect(abs(CMSampleBufferGetPresentationTimeStamp(shifted).seconds - 0.5) < 1e-6)
        #expect(CMSampleBufferGetNumSamples(shifted) == 1024)
        // 1024 samples at 48 kHz, not 1024 × the buffer length.
        #expect(abs(CMSampleBufferGetDuration(shifted).seconds - originalDuration.seconds) < 1e-9)
        #expect(abs(CMSampleBufferGetDuration(shifted).seconds - 1024.0 / 48_000.0) < 1e-9)
    }

    @Test func micAudioIsPlacedRelativeToFirstVideoFrame() {
        // Mic buffer captured 300 ms after the first video frame (e.g. a slow Bluetooth
        // mic) belongs at 0.3 s, not at 0.
        let time = MediaTiming.recordingTime(
            hostTime: CMTime(seconds: 1000.3, preferredTimescale: 1_000_000_000),
            firstVideoFrameHostTime: CMTime(seconds: 1000, preferredTimescale: 1_000_000_000)
        )
        #expect(abs(time.seconds - 0.3) < 1e-6)
    }
}

@Suite("EditHistory")
struct EditHistoryTests {
    @Test func undoAndRedoWalkThroughStates() {
        var history = EditHistory<Int>()
        var state = 0

        history.record(state, actionName: "One", now: 0)
        state = 1
        history.record(state, actionName: "Two", now: 5)
        state = 2

        #expect(history.canUndo)
        #expect(history.undoActionName == "Two")

        state = history.undo(from: state) ?? state
        #expect(state == 1)
        #expect(history.redoActionName == "Two")

        state = history.undo(from: state) ?? state
        #expect(state == 0)
        #expect(!history.canUndo)
        #expect(history.undo(from: state) == nil)

        state = history.redo(from: state) ?? state
        #expect(state == 1)
        state = history.redo(from: state) ?? state
        #expect(state == 2)
        #expect(!history.canRedo)
    }

    @Test func newEditClearsRedo() {
        var history = EditHistory<Int>()
        history.record(0, actionName: "Edit", now: 0)
        _ = history.undo(from: 1)
        #expect(history.canRedo)

        history.record(0, actionName: "Other edit", now: 10)
        #expect(!history.canRedo)
        #expect(history.undoActionName == "Other edit")
    }

    @Test func rapidEditsWithSameKeyCoalesce() {
        var history = EditHistory<String>(coalescingInterval: 1.0)
        // Typing "abc": each keystroke records the text from before it.
        history.record("", actionName: "Type", coalescingKey: AnyHashable("text"), now: 0.0)
        history.record("a", actionName: "Type", coalescingKey: AnyHashable("text"), now: 0.3)
        history.record("ab", actionName: "Type", coalescingKey: AnyHashable("text"), now: 0.6)

        #expect(history.undoStack.count == 1)
        // Undo goes back to before the burst.
        #expect(history.undo(from: "abc") == "")
    }

    @Test func coalescingStopsAfterAPauseOrADifferentKey() {
        var history = EditHistory<Int>(coalescingInterval: 1.0)
        history.record(0, actionName: "Type", coalescingKey: AnyHashable("text"), now: 0)
        history.record(1, actionName: "Type", coalescingKey: AnyHashable("text"), now: 5)
        history.record(2, actionName: "Toggle", coalescingKey: AnyHashable("toggle"), now: 5.1)
        history.record(3, actionName: "Toggle", now: 5.2)
        #expect(history.undoStack.count == 4)
    }

    @Test func undoBreaksCoalescing() {
        var history = EditHistory<Int>(coalescingInterval: 1.0)
        history.record(0, actionName: "Type", coalescingKey: AnyHashable("text"), now: 0)
        _ = history.undo(from: 1)
        history.record(0, actionName: "Type", coalescingKey: AnyHashable("text"), now: 0.2)
        #expect(history.undoStack.count == 1)
        #expect(!history.canRedo)
    }

    @Test func keepsOnlyTheMostRecentSteps() {
        var history = EditHistory<Int>(limit: 3)
        for value in 0..<5 {
            history.record(value, actionName: "Step \(value)", now: Double(value) * 10)
        }
        #expect(history.undoStack.map(\.state) == [2, 3, 4])
    }
}

@Suite("CaptureGeometry")
struct CaptureGeometryTests {
    @Test func pixelSizeScalesPoints() {
        let size = CaptureGeometry.pixelSize(points: CGSize(width: 1512, height: 982), scale: 2)
        #expect(size.width == 3024)
        #expect(size.height == 1964)
    }

    @Test func pixelSizeRoundsDownToEvenNumbers() {
        let size = CaptureGeometry.pixelSize(points: CGSize(width: 801, height: 599), scale: 1)
        #expect(size.width == 800)
        #expect(size.height == 598)
    }

    @Test func pixelSizeHandlesFractionalScaleAndEmptySizes() {
        let fractional = CaptureGeometry.pixelSize(points: CGSize(width: 1001, height: 700.5), scale: 1.5)
        #expect(fractional.width % 2 == 0)
        #expect(fractional.height % 2 == 0)
        #expect(abs(fractional.width - 1502) <= 1)

        let empty = CaptureGeometry.pixelSize(points: .zero, scale: 2)
        #expect(empty.width == 2)
        #expect(empty.height == 2)
    }

    @Test func capturePointFlipsToBottomLeftPixels() {
        // Main display: origin at (0, 0), 2x.
        let topLeft = CaptureGeometry.capturePoint(
            global: CGPoint(x: 10, y: 20), origin: .zero, scale: 2, pixelHeight: 1964
        )
        #expect(abs(topLeft.x - 20) < 1e-9)
        #expect(abs(topLeft.y - (1964 - 40)) < 1e-9)
    }

    @Test func capturePointIsRelativeToWindowOrigin() {
        // A 400x300 pt window whose top-left is at (100, 50) in global space.
        let center = CaptureGeometry.capturePoint(
            global: CGPoint(x: 300, y: 200), origin: CGPoint(x: 100, y: 50), scale: 2, pixelHeight: 600
        )
        #expect(abs(center.x - 400) < 1e-9)
        #expect(abs(center.y - 300) < 1e-9)
    }

    @Test func sourceRectLeavesOutTheMenuBar() {
        let rect = CaptureGeometry.sourceRect(displaySize: CGSize(width: 1512, height: 982), topInset: 37)
        #expect(rect == CGRect(x: 0, y: 37, width: 1512, height: 945))
    }

    @Test func sourceRectClampsBadInsets() {
        let size = CGSize(width: 1920, height: 1080)
        #expect(CaptureGeometry.sourceRect(displaySize: size, topInset: 0) == CGRect(origin: .zero, size: size))
        #expect(CaptureGeometry.sourceRect(displaySize: size, topInset: -5) == CGRect(origin: .zero, size: size))
        #expect(CaptureGeometry.sourceRect(displaySize: size, topInset: 5000).height == 540)
        #expect(CaptureGeometry.sourceRect(displaySize: size, topInset: .nan) == CGRect(origin: .zero, size: size))
    }

    @Test func resolvedDisplayPrefersTheChosenDisplay() {
        #expect(CaptureGeometry.resolvedDisplayID(preferred: 7, available: [1, 7], main: 1) == 7)
    }

    @Test func resolvedDisplayFallsBackToMainThenAny() {
        #expect(CaptureGeometry.resolvedDisplayID(preferred: nil, available: [3, 1], main: 1) == 1)
        #expect(CaptureGeometry.resolvedDisplayID(preferred: 9, available: [3, 1], main: 1) == 1)
        #expect(CaptureGeometry.resolvedDisplayID(preferred: 9, available: [3], main: 1) == 3)
        #expect(CaptureGeometry.resolvedDisplayID(preferred: 9, available: [], main: 1) == nil)
    }

    @Test func capturePointOnSecondaryDisplayLeftOfMain() {
        // A display arranged to the left of the main one has a negative global origin.
        let point = CaptureGeometry.capturePoint(
            global: CGPoint(x: -1900, y: 0), origin: CGPoint(x: -1920, y: 0), scale: 1, pixelHeight: 1080
        )
        #expect(abs(point.x - 20) < 1e-9)
        #expect(abs(point.y - 1080) < 1e-9)
    }
}

@Suite("VideoCodecChoice")
struct VideoCodecChoiceTests {
    @Test func commonSizesUseH264() {
        #expect(VideoCodecChoice.forFrame(width: 1920, height: 1080) == .h264)
        #expect(VideoCodecChoice.forFrame(width: 3024, height: 1964) == .h264)  // 14" MacBook Pro
        #expect(VideoCodecChoice.forFrame(width: 3456, height: 2234) == .h264)  // 16" MacBook Pro
        #expect(VideoCodecChoice.forFrame(width: 3840, height: 2160) == .h264)  // 4K
        #expect(VideoCodecChoice.forFrame(width: 4096, height: 2304) == .h264)  // level 5.2 limit
    }

    @Test func fiveAndSixKUseHEVC() {
        #expect(VideoCodecChoice.forFrame(width: 5120, height: 2880) == .hevc)  // Studio Display
        #expect(VideoCodecChoice.forFrame(width: 6016, height: 3384) == .hevc)  // Pro Display XDR
    }

    @Test func tallFramesOverTheSideLimitUseHEVC() {
        #expect(VideoCodecChoice.forFrame(width: 1200, height: 4200) == .hevc)
    }
}

@Suite("OverlayLayout")
struct OverlayLayoutTests {
    private let canvas = CGSize(width: 1920, height: 1080)
    private let text = CGSize(width: 120, height: 24)

    @Test func watermarkDefaultsToBottomRight() {
        let origin = OverlayLayout.watermarkOrigin(size: text, canvas: canvas, margin: 24, avoiding: nil)
        #expect(origin == CGPoint(x: 1920 - 120 - 24, y: 24))
    }

    @Test func watermarkMovesAwayFromABottomRightBubble() {
        let bubble = CGRect(x: 1920 - 194 - 38, y: 38, width: 194, height: 194)
        let origin = OverlayLayout.watermarkOrigin(size: text, canvas: canvas, margin: 24, avoiding: bubble)
        #expect(origin == CGPoint(x: 24, y: 24))
    }

    @Test func watermarkStaysPutWhenTheBubbleIsElsewhere() {
        let bubble = CGRect(x: 38, y: 1080 - 194 - 38, width: 194, height: 194)
        let origin = OverlayLayout.watermarkOrigin(size: text, canvas: canvas, margin: 24, avoiding: bubble)
        #expect(origin == CGPoint(x: 1920 - 120 - 24, y: 24))
    }
}
