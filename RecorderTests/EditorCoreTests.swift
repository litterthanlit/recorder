import CoreGraphics
import Foundation
import Testing
@testable import RecorderCore

@Suite("Editor shortcuts")
struct EditorShortcutTests {
    private let command = KeyCombo.Modifier.command
    private let shift = KeyCombo.Modifier.shift
    private let option = KeyCombo.Modifier.option

    private func run(_ keyCode: UInt32, _ modifiers: UInt32 = 0, _ character: String? = nil) -> EditorCommand? {
        EditorShortcuts.command(keyCode: keyCode, modifiers: modifiers, character: character)
    }

    @Test func playbackAndStepping() {
        #expect(run(KeyNames.Code.space) == .togglePlayback)
        #expect(run(KeyNames.Code.space, command) == nil)
        #expect(run(KeyNames.Code.leftArrow) == .stepFrames(-1))
        #expect(run(KeyNames.Code.rightArrow, shift) == .stepSeconds(1))
        #expect(run(KeyNames.Code.leftArrow, command) == .goToStart)
        #expect(run(KeyNames.Code.rightArrow, option) == .nudgeSelection(0.1))
        #expect(run(KeyNames.Code.leftArrow, option | shift) == .nudgeSelection(-1))
    }

    @Test func lettersFollowTheLayout() {
        // AZERTY: the key in QWERTY's W position types "z".
        #expect(run(0x0D, 0, "z") == .addZoom)
        #expect(run(0x06, 0, "w") == nil)
        #expect(run(0x01, 0, "s") == .split)
        #expect(run(0x0B, command, "b") == .split)
        #expect(run(0x11, 0, "T") == .addText)
        #expect(run(0x0B, 0, "b") == .addBlur)
    }

    @Test func commandShortcuts() {
        #expect(run(0x0E, command, "e") == .export)
        #expect(run(0x18, command, "=") == .timelineZoomIn)
        #expect(run(0x18, command | shift, "+") == .timelineZoomIn)
        #expect(run(0x1B, command, "-") == .timelineZoomOut)
        #expect(run(0x1D, command, "0") == .timelineZoomToFit)
        // Undo belongs to the menu.
        #expect(run(0x06, command, "z") == nil)
    }

    @Test func deletingAndEscaping() {
        #expect(run(KeyNames.Code.delete) == .deleteSelection)
        #expect(run(KeyNames.Code.forwardDelete) == .deleteSelection)
        #expect(run(KeyNames.Code.delete, command) == .deleteSelection)
        #expect(run(KeyNames.Code.delete, option) == nil)
        #expect(run(KeyNames.Code.escape) == .clearSelection)
    }
}

@Suite("Timeline geometry")
struct TimelineGeometryTests {
    @Test func fittingShowsTheWholeEdit() {
        let scale = TimelineScale.fitting(duration: 60, width: 600)
        #expect(isClose(scale.pointsPerSecond, 10))
        #expect(isClose(scale.contentWidth, 600))
        #expect(isClose(scale.x(for: 30), 300))
        #expect(isClose(scale.time(for: 150), 15))
        #expect(isClose(scale.time(for: -20), 0))
        #expect(isClose(scale.time(for: 10_000), 60))
    }

    @Test func zoomingOutStopsAtTheFit() {
        let scale = TimelineScale(pointsPerSecond: 40, duration: 60)
        let zoomedOut = scale.zoomed(by: 0.1, minimumWidth: 600)
        #expect(isClose(zoomedOut.pointsPerSecond, 10))
        let zoomedIn = scale.zoomed(by: 2, minimumWidth: 600)
        #expect(isClose(zoomedIn.pointsPerSecond, 80))
    }

    @Test func rulerPicksReadableIntervals() {
        let coarse = TimelineRuler.intervals(pointsPerSecond: 10, minimumSpacing: 72)
        #expect(isClose(coarse.major, 10))
        let fine = TimelineRuler.intervals(pointsPerSecond: 400, minimumSpacing: 72)
        #expect(isClose(fine.major, 0.25))

        let ticks = TimelineRuler.ticks(from: 0, to: 10, pointsPerSecond: 72, minimumSpacing: 72)
        let majors = ticks.filter(\.isMajor).map(\.time)
        #expect(majors.count == 11)
        #expect(isClose(majors[3], 3))
        #expect(ticks.count == 41)
    }

    @Test func rulerLabels() {
        #expect(TimelineRuler.label(for: 65, majorInterval: 5) == "1:05")
        #expect(TimelineRuler.label(for: 1.5, majorInterval: 0.5) == "0:01.5")
        #expect(Timecode.precise(65.37) == "1:05.3")
        #expect(Timecode.short(59.6) == "1:00")
        #expect(Timecode.spoken(65.5) == "1 minute 5.5 seconds")
    }

    @Test func snappingPrefersTheClosestCandidate() {
        #expect(isClose(TimelineSnapper.snap(4.96, to: [5, 4.9], tolerance: 0.1), 5))
        #expect(isClose(TimelineSnapper.snap(4.5, to: [5], tolerance: 0.1), 4.5))
        #expect(isClose(TimelineSnapper.snap(4.5, to: [], tolerance: 1), 4.5))
    }
}

@Suite("Waveform")
struct WaveformTests {
    @Test func peaksAreTheLoudestSampleInEachBucket() {
        let peaks = Waveform.peaks(from: [0.1, -0.5, 0.2, 0.3, -0.9], bucketSize: 2)
        #expect(peaks.count == 3)
        #expect(isClose(Double(peaks[0]), 0.5, tolerance: 1e-6))
        #expect(isClose(Double(peaks[1]), 0.3, tolerance: 1e-6))
        #expect(isClose(Double(peaks[2]), 0.9, tolerance: 1e-6))
        #expect(Waveform.peaks(from: [], bucketSize: 10).isEmpty)
    }

    @Test func peakOverARange() {
        let peaks: [Float] = [0.1, 0.2, 0.8, 0.3]
        #expect(isClose(Double(Waveform.peak(in: peaks, rate: 2, from: 0, to: 0.9)), 0.2, tolerance: 1e-6))
        #expect(isClose(Double(Waveform.peak(in: peaks, rate: 2, from: 1, to: 5)), 0.8, tolerance: 1e-6))
        #expect(Waveform.peak(in: [], from: 0, to: 1) == 0)
    }

    @Test func levelsUseADecibelScale() {
        #expect(Waveform.displayLevel(0) == 0)
        #expect(isClose(Waveform.displayLevel(1), 1))
        // -24 dB is half height.
        #expect(isClose(Waveform.displayLevel(Float(pow(10.0, -24.0 / 20))), 0.5, tolerance: 1e-4))
    }
}

@Suite("Zoom focus")
struct ZoomFocusTests {
    private func zoom(center: CGPoint, scale: CGFloat) -> ZoomKeyframe {
        ZoomKeyframe(startTime: 1, peakTime: 1.4, endTime: 3, center: center, scale: scale, source: .auto)
    }

    @Test func focusMatchesTheCrop() {
        let rect = ZoomKeyframeEditor.focusRect(for: zoom(center: CGPoint(x: 0.5, y: 0.5), scale: 2))
        #expect(isClose(rect, CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)))
        let atEdge = ZoomKeyframeEditor.focusRect(for: zoom(center: CGPoint(x: 0.95, y: 0.1), scale: 2))
        #expect(isClose(atEdge, CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)))
    }

    @Test func movingKeepsTheFocusInside() {
        let moved = ZoomKeyframeEditor.keyframe(zoom(center: CGPoint(x: 0.5, y: 0.5), scale: 2), movingFocusTo: CGPoint(x: 0.9, y: 0.05))
        #expect(isClose(moved.centerX, 0.75))
        #expect(isClose(moved.centerY, 0.25))
    }

    @Test func resizingSetsTheScale() {
        let focused = ZoomKeyframeEditor.keyframe(
            zoom(center: CGPoint(x: 0.5, y: 0.5), scale: 2),
            focusingOn: CGRect(x: 0.1, y: 0.1, width: 0.25, height: 0.2)
        )
        #expect(isClose(focused.scale, 4))
        #expect(isClose(focused.centerX, 0.225))
        #expect(isClose(focused.centerY, 0.2))
        let wide = ZoomKeyframeEditor.keyframe(zoom(center: CGPoint(x: 0.5, y: 0.5), scale: 2), focusingOn: CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(isClose(wide.scale, ZoomKeyframeEditor.focusScaleRange.lowerBound))
    }

    @Test func viewRectInvertsTheSelectionMapping() throws {
        let content = CGRect(x: 20, y: 10, width: 400, height: 225)
        let crop = NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let selection = CGRect(x: 120, y: 60, width: 100, height: 50)
        let source = try #require(ZoomKeyframeEditor.sourceRect(forSelection: selection, contentFrame: content, visibleCrop: crop))
        let back = ZoomKeyframeEditor.viewRect(forSource: source, contentFrame: content, visibleCrop: crop)
        #expect(isClose(back, selection))
    }
}
