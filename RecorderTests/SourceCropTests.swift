import CoreGraphics
import Foundation
import Testing
@testable import RecorderCore

/// A crop in the upper middle of the recording (normalized, bottom-left origin).
private let window = CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.4)

private func matches(_ rect: NormalizedRect, _ expected: CGRect) -> Bool {
    isClose(CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height), expected)
}

private func zoom(center: CGPoint, scale: CGFloat = 2) -> ZoomKeyframe {
    ZoomKeyframe(startTime: 0, peakTime: 1, endTime: 3, center: center, scale: scale, source: .manual)
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

@Suite("Source crop")
struct SourceCropTests {
    @Test func cropsAreKeptInsideTheRecording() {
        #expect(SourceCrop.sanitized(window) == window)
        let outside = SourceCrop.sanitized(CGRect(x: 0.8, y: -0.2, width: 0.5, height: 0.5))
        #expect(outside.map { isClose($0, CGRect(x: 0.8, y: 0, width: 0.2, height: 0.3)) } == true)
        let tiny = SourceCrop.sanitized(CGRect(x: 0.5, y: 0.5, width: 0.001, height: 0.2))
        #expect(tiny.map { isClose($0.width, SourceCrop.minimumSide) } == true)
        // The whole recording, or nothing at all, is no crop.
        #expect(SourceCrop.sanitized(CGRect(x: 0, y: 0, width: 1, height: 1)) == nil)
        #expect(SourceCrop.sanitized(CGRect(x: 0.001, y: 0, width: 0.999, height: 1)) == nil)
        #expect(SourceCrop.sanitized(CGRect(x: 2, y: 2, width: 1, height: 1)) == nil)
        #expect(SourceCrop.sanitized(CGRect(x: CGFloat.nan, y: 0, width: 0.5, height: 0.5)) == nil)
        #expect(SourceCrop.base(nil) == SourceCrop.full)
    }

    @Test func theCropSetsTheContentSize() {
        let source = CGSize(width: 3000, height: 2000)
        #expect(SourceCrop.contentSize(source: source, crop: nil) == source)
        #expect(SourceCrop.contentSize(source: source, crop: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)) == CGSize(width: 1500, height: 1000))
        let joined = SourceCrop.union([CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), CGRect(x: 0.5, y: 0.2, width: 0.1, height: 0.3)])
        #expect(joined.map { isClose($0, CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.4)) } == true)
        #expect(SourceCrop.union([]) == nil)
    }

    @Test func autoShapeAndSourceSizeFollowTheCrop() {
        var settings = ProjectEditSettings()
        settings.sourceCrop = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let source = CGSize(width: 3000, height: 2000)
        settings.canvas = CanvasSpec(aspect: .auto, resolution: .source)
        #expect(settings.canvasPixelSize(source: source) == CGSize(width: 1500, height: 1000))
        settings.canvas = CanvasSpec(aspect: .auto, resolution: .hd1080)
        #expect(settings.canvasPixelSize(source: source) == CGSize(width: 1620, height: 1080))
        // A fixed shape doesn't change.
        settings.canvas = CanvasSpec(aspect: .widescreen, resolution: .hd1080)
        #expect(settings.canvasPixelSize(source: source) == CGSize(width: 1920, height: 1080))
    }

    @Test func theCropIsSavedAndReadBack() throws {
        var settings = ProjectEditSettings()
        settings.sourceCrop = window
        let decoded = try JSONDecoder().decode(ProjectEditSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.sourceCrop == window)
        #expect(decoded == settings)

        // A crop of the whole recording is read as none.
        settings.sourceCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
        let whole = try JSONDecoder().decode(ProjectEditSettings.self, from: JSONEncoder().encode(settings))
        #expect(whole.sourceCrop == nil)
        let legacy = try JSONDecoder().decode(ProjectEditSettings.self, from: Data("{}".utf8))
        #expect(legacy.sourceCrop == nil)
    }
}

@Suite("Zooms inside a crop")
struct CroppedZoomTests {
    @Test func theCameraRestsOnTheCrop() {
        let empty = ZoomInterpolator(keyframes: [], base: window)
        #expect(matches(empty.cropRect(at: 1), window))
        #expect(isClose(empty.scale(at: 1), 1))
        // Without a crop it's the whole frame, as before.
        #expect(ZoomInterpolator(keyframes: []).cropRect(at: 1) == .fullFrame)
    }

    @Test func zoomsAreRelativeToTheCropAndStayInside() {
        let interpolator = ZoomInterpolator(keyframes: [zoom(center: CGPoint(x: 0.5, y: 0.7))], base: window)
        #expect(matches(interpolator.cropRect(at: 1.5), CGRect(x: 0.375, y: 0.6, width: 0.25, height: 0.2)))
        #expect(isClose(interpolator.scale(at: 1.5), 2))
        #expect(matches(interpolator.cropRect(at: 5), window))

        let outside = ZoomInterpolator(keyframes: [zoom(center: CGPoint(x: 0.1, y: 0.1))], base: window)
        #expect(matches(outside.cropRect(at: 1.5), CGRect(x: 0.25, y: 0.5, width: 0.25, height: 0.2)))
    }

    @Test func noCropMeansTheOldMath() {
        let keyframes = [zoom(center: CGPoint(x: 0.8, y: 0.3), scale: 2.5)]
        let plain = ZoomInterpolator(keyframes: keyframes)
        let explicit = ZoomInterpolator(keyframes: keyframes, base: SourceCrop.full)
        for time in stride(from: 0.0, through: 3.5, by: 0.25) {
            #expect(plain.cropRect(at: time) == explicit.cropRect(at: time))
        }
        // The hold: 1 / 2.5 of the frame, kept inside it.
        #expect(matches(plain.cropRect(at: 1.5), CGRect(x: 0.6, y: 0.1, width: 0.4, height: 0.4)))
    }

    @Test func aimingStaysInsideTheCrop() {
        let keyframe = zoom(center: CGPoint(x: 0.5, y: 0.7))
        #expect(isClose(ZoomKeyframeEditor.focusRect(for: keyframe, base: window), CGRect(x: 0.375, y: 0.6, width: 0.25, height: 0.2)))

        let moved = ZoomKeyframeEditor.keyframe(keyframe, movingFocusTo: CGPoint(x: 0.9, y: 0.95), base: window)
        #expect(isClose(moved.centerX, 0.625) && isClose(moved.centerY, 0.8))

        // A box a fifth of the crop's width and a quarter of its height: 4× shows all of it.
        let focused = ZoomKeyframeEditor.keyframe(keyframe, focusingOn: CGRect(x: 0.4, y: 0.6, width: 0.1, height: 0.1), base: window)
        #expect(isClose(focused.scale, 4))
        #expect(isClose(focused.centerX, 0.45) && isClose(focused.centerY, 0.65))

        let manual = ZoomKeyframeEditor.makeManualKeyframe(
            at: 2,
            normalizedRect: CGRect(x: 0.3, y: 0.55, width: 0.2, height: 0.2),
            duration: 10,
            base: window
        )
        #expect(isClose(manual.scale, 2))
    }
}

@Suite("Agent crop")
struct AgentCropTests {
    private let take = AgentEditTake(duration: 20, sourceSize: CGSize(width: 2000, height: 1000))

    private func snapshot() -> EditorSnapshot {
        var settings = ProjectEditSettings()
        settings.setTimeline(EditTimeline(sourceDuration: 20))
        return EditorSnapshot(keyframes: [], editSettings: settings)
    }

    @Test func cropsToARectReadOffAFrame() throws {
        var edited = snapshot()
        let box: JSONValue = ["x": 0.25, "y": 0.1, "width": 0.5, "height": 0.5]
        let notes = try AgentEdits.setCrop(&edited, arguments: AgentArguments(["rect": box]), take: take)
        // Top-left y 0.1 is bottom-left y 0.4.
        #expect(edited.editSettings.sourceCrop.map { isClose($0, CGRect(x: 0.25, y: 0.4, width: 0.5, height: 0.5)) } == true)
        #expect(notes.first == "Cropped to 1000×500 px of the recording; zooms now push in within it.")
        #expect(notes.count == 2)

        let report = TakeDescription.cropJSON(edited.editSettings.sourceCrop, source: take.sourceSize)
        #expect(report["rect"]?["y"]?.doubleValue == 0.1)
        #expect(report["pixels"]?.stringValue == "1000x500")

        // Zooms now push in within the crop.
        _ = try AgentEdits.editZooms(
            &edited,
            operations: [AgentArguments(["op": "add", "start": 2, "end": 5, "point": ["x": 0.1, "y": 0.1], "scale": 2])],
            take: take,
            timeBase: .source
        )
        let added = try #require(edited.keyframes.first)
        #expect(isClose(added.centerX, 0.375) && isClose(added.centerY, 0.775))
    }

    @Test func growsByAMarginAndClears() throws {
        var edited = snapshot()
        let box: JSONValue = ["x": 0.25, "y": 0.1, "width": 0.5, "height": 0.5]
        _ = try AgentEdits.setCrop(&edited, arguments: AgentArguments(["rect": box, "margin": 0.05]), take: take)
        #expect(edited.editSettings.sourceCrop.map { isClose($0, CGRect(x: 0.2, y: 0.35, width: 0.6, height: 0.6)) } == true)

        let notes = try AgentEdits.setCrop(&edited, arguments: AgentArguments(["clear": true]), take: take)
        #expect(edited.editSettings.sourceCrop == nil)
        #expect(notes == ["Showing the whole recording again."])
    }

    @Test func explainsBadCrops() {
        var edited = snapshot()
        let nothing = failure { _ = try AgentEdits.setCrop(&edited, arguments: AgentArguments(["take_id": "latest"]), take: take) }
        #expect(nothing?.hasPrefix("set_crop needs rect") == true)
        let notCropped = failure { _ = try AgentEdits.setCrop(&edited, arguments: AgentArguments(["clear": true]), take: take) }
        #expect(notCropped?.hasPrefix("The take isn't cropped") == true)
        let whole: JSONValue = ["x": 0, "y": 0, "width": 1, "height": 1]
        let everything = failure { _ = try AgentEdits.setCrop(&edited, arguments: AgentArguments(["rect": whole]), take: take) }
        #expect(everything?.hasPrefix("That rect is the whole recording") == true)
    }
}
