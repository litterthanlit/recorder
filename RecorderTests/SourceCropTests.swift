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

    private let focus = [
        AppFocusEvent(timestamp: 0, bundleID: "com.acme.app", appName: "Acme", windowRect: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6)),
        AppFocusEvent(timestamp: 4, bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", windowRect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)),
        AppFocusEvent(timestamp: 8, bundleID: "com.acme.app", appName: "Acme", windowRect: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.6))
    ]

    @Test func followsAnAppsWindow() throws {
        let focused = AgentEditTake(duration: 20, sourceSize: CGSize(width: 2000, height: 1000), appFocus: focus)
        var edited = snapshot()
        let notes = try AgentEdits.setCrop(&edited, arguments: AgentArguments(["app": "acme"]), take: focused)
        // At rest where the window spent longest (8–20 s), moving with it at 8 s. Slack's
        // window doesn't count.
        let settings = edited.editSettings
        #expect(settings.sourceCrop.map { isClose($0, CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.6)) } == true)
        #expect(settings.cropPath?.app == "Acme")
        #expect(isClose(settings.cropBase(at: 3), CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6)))
        #expect(isClose(settings.cropBase(at: 12), CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.6)))
        let between = settings.cropBase(at: 7.85)
        #expect(between.minX > 0.1 && between.minX < 0.2 && isClose(between.width, 0.5))
        #expect(notes.first == "Cropped to Acme's window (1000×600 px), following it as it moves (it moved once); zooms push in within it.")

        // By bundle ID, with a margin: the path grows with it.
        _ = try AgentEdits.setCrop(&edited, arguments: AgentArguments(["app": "com.acme.app", "margin": 0.05]), take: focused)
        #expect(edited.editSettings.sourceCrop.map { isClose($0, CGRect(x: 0.15, y: 0.15, width: 0.6, height: 0.7)) } == true)
        #expect(isClose(edited.editSettings.cropBase(at: 3), CGRect(x: 0.05, y: 0.15, width: 0.6, height: 0.7)))

        // A fixed rect holds still again.
        let box: JSONValue = ["x": 0.25, "y": 0.1, "width": 0.5, "height": 0.5]
        _ = try AgentEdits.setCrop(&edited, arguments: AgentArguments(["rect": box]), take: focused)
        #expect(edited.editSettings.cropPath == nil)
    }

    @Test func cropsToEverywhereAnAppsWindowWas() throws {
        let focused = AgentEditTake(duration: 20, sourceSize: CGSize(width: 2000, height: 1000), appFocus: focus)
        var edited = snapshot()
        _ = try AgentEdits.setCrop(&edited, arguments: AgentArguments(["app": "acme", "follow": false]), take: focused)
        // Both places the window was: x 0.1–0.7, y 0.2–0.8, held still.
        #expect(edited.editSettings.sourceCrop.map { isClose($0, CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.6)) } == true)
        #expect(edited.editSettings.cropPath == nil)

        // By bundle ID, with a margin.
        _ = try AgentEdits.setCrop(&edited, arguments: AgentArguments(["app": "com.acme.app", "follow": false, "margin": 0.05]), take: focused)
        #expect(edited.editSettings.sourceCrop.map { isClose($0, CGRect(x: 0.05, y: 0.15, width: 0.7, height: 0.7)) } == true)

        let unknown = failure { _ = try AgentEdits.setCrop(&edited, arguments: AgentArguments(["app": "Figma"]), take: focused) }
        #expect(unknown == "No window of \"Figma\" showed in the recording. Apps in this take: \"Acme\", \"Slack\".")
        // Takes from before Trace kept which app was in front.
        let older = failure { _ = try AgentEdits.setCrop(&edited, arguments: AgentArguments(["app": "Acme"]), take: take) }
        #expect(older?.hasPrefix("This take doesn't record which app was in front") == true)
    }

    @Test func explainsBadCrops() {
        var edited = snapshot()
        let nothing = failure { _ = try AgentEdits.setCrop(&edited, arguments: AgentArguments(["take_id": "latest"]), take: take) }
        #expect(nothing?.hasPrefix("set_crop needs app") == true)
        let notCropped = failure { _ = try AgentEdits.setCrop(&edited, arguments: AgentArguments(["clear": true]), take: take) }
        #expect(notCropped?.hasPrefix("The take isn't cropped") == true)
        let whole: JSONValue = ["x": 0, "y": 0, "width": 1, "height": 1]
        let everything = failure { _ = try AgentEdits.setCrop(&edited, arguments: AgentArguments(["rect": whole]), take: take) }
        #expect(everything?.hasPrefix("That rect is the whole recording") == true)
    }
}

@Suite("Crop following a window")
struct CropPathTests {
    private func acme(_ time: TimeInterval, _ rect: CGRect?) -> AppFocusEvent {
        AppFocusEvent(timestamp: time, bundleID: "com.acme.app", appName: "Acme", windowRect: rect)
    }

    private let left = CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.5)
    private let right = CGRect(x: 0.5, y: 0.2, width: 0.4, height: 0.5)

    @Test func glidesBetweenPlacesAndEases() {
        let path = CropPath(points: [
            CropPath.Point(time: 2, rect: left),
            CropPath.Point(time: 3, rect: left),
            CropPath.Point(time: 4, rect: right)
        ])
        // Holds before the first point, between equal points and after the last.
        #expect(isClose(path.rect(at: 0), left))
        #expect(isClose(path.rect(at: 2.5), left))
        #expect(isClose(path.rect(at: 6), right))
        // Halfway through the glide, halfway there. Smoothing sets off gently a moment
        // early and settles a moment late, instead of jerking at the ends.
        #expect(isClose(path.rect(at: 3.5), CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.5)))
        #expect(isClose(path.straight(at: 3.1).minX, 0.14))
        let setOff = path.rect(at: 2.9).minX
        #expect(setOff > 0.1 && setOff < 0.105)
        let settling = path.rect(at: 4.1).minX
        #expect(settling < 0.5 && settling > 0.495)
        #expect(isClose(CropPath(points: []).rect(at: 1), SourceCrop.full))
    }

    @Test func followsTheWindowWhereverItWent() throws {
        let events = [
            acme(0, left),
            AppFocusEvent(timestamp: 3, bundleID: nil, appName: "Slack", windowRect: right),
            acme(5, left),
            // Dragged across in a second, seen four times a second.
            acme(10, left.offsetBy(dx: 0.1, dy: 0)),
            acme(10.25, left.offsetBy(dx: 0.2, dy: 0)),
            acme(10.5, left.offsetBy(dx: 0.3, dy: 0)),
            acme(10.75, right)
        ]
        let window = try #require(WindowCrop.following("acme", in: events, duration: 30))
        // At rest where it stayed longest: on the right, from 10.75 s.
        #expect(window.crop.map { isClose($0, right) } == true)
        #expect(window.moves == 1)
        let path = try #require(window.path)
        #expect(path.app == "Acme")
        // Still until a glide into the drag, then straight along it.
        #expect(isClose(path.straight(at: 9), left))
        #expect(isClose(path.straight(at: 9.65), left))
        #expect(isClose(path.straight(at: 10.125), left.offsetBy(dx: 0.15, dy: 0)))
        #expect(isClose(path.straight(at: 11), right))
        // Slack's window doesn't count.
        #expect(!path.points.contains { isClose($0.rect.minX, 0.5) && $0.time < 10 })
    }

    @Test func keepsTheShapeWhenTheWindowResizes() throws {
        let bigger = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        let tiny = CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1)
        let events = [acme(0, left), acme(10, bigger), acme(12, tiny), acme(14, left)]
        let window = try #require(WindowCrop.following("Acme", in: events, duration: 20))
        let crop = try #require(window.crop)
        #expect(isClose(crop, left))
        let path = try #require(window.path)
        let shape = left.height / left.width
        for point in path.points {
            #expect(isClose(point.rect.height / point.rect.width, shape, tolerance: 1e-9))
            #expect(point.rect.minX >= 0 && point.rect.minY >= 0 && point.rect.maxX <= 1 + 1e-9 && point.rect.maxY <= 1 + 1e-9)
        }
        // The bigger window is held whole (zooming out); the tiny one isn't blown up past
        // 0.6 of the usual size.
        let wide = path.straight(at: 11)
        #expect(wide.width >= 0.8 - 1e-9 && wide.height >= 0.8 - 1e-9)
        #expect(isClose(path.straight(at: 13).width, 0.4 * WindowCrop.minimumScale))
        #expect(window.moves == 3)
    }

    @Test func aStillWindowNeedsNoPath() throws {
        let still = try #require(WindowCrop.following("Acme", in: [acme(0, left), acme(4, left.offsetBy(dx: 0.001, dy: 0))], duration: 10))
        #expect(still.crop.map { isClose($0, left, tolerance: 0.002) } == true)
        #expect(still.path == nil && still.moves == 0)
        // A window over the whole recording leaves nothing to crop.
        let whole = try #require(WindowCrop.following("Acme", in: [acme(0, SourceCrop.full)], duration: 10))
        #expect(whole.crop == nil && whole.path == nil)
        // Never in the recording.
        #expect(WindowCrop.following("Acme", in: [acme(0, nil)], duration: 10) == nil)
        #expect(WindowCrop.following("Figma", in: [acme(0, left)], duration: 10) == nil)
    }

    @Test func fitsRectsToTheCropsShape() throws {
        // Taller than the shape: widened around its centre; kept inside the recording.
        let tall = try #require(SourceCrop.fitted(CGRect(x: 0.9, y: 0.1, width: 0.1, height: 0.4), shape: 1))
        #expect(isClose(tall, CGRect(x: 0.6, y: 0.1, width: 0.4, height: 0.4)))
        // Too big for the recording: the largest of its shape that fits.
        let huge = try #require(SourceCrop.fitted(CGRect(x: 0, y: 0, width: 1, height: 1), shape: 2))
        #expect(isClose(huge, CGRect(x: 0.25, y: 0, width: 0.5, height: 1)))
        #expect(SourceCrop.fitted(CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1), shape: 1) == nil)
        #expect(SourceCrop.fitted(left, shape: 0) == nil)
    }

    @Test func zoomsRestOnTheMovingCrop() {
        let path = CropPath(points: [CropPath.Point(time: 0, rect: left), CropPath.Point(time: 5, rect: left), CropPath.Point(time: 6, rect: right)])
        let interpolator = ZoomInterpolator(keyframes: [], base: left, path: path)
        #expect(matches(interpolator.cropRect(at: 1), left))
        #expect(matches(interpolator.cropRect(at: 8), right))
        // A zoom aimed at the left stays inside the window once it has moved right.
        let zoomed = ZoomInterpolator(
            keyframes: [ZoomKeyframe(startTime: 6, peakTime: 7, endTime: 9, center: CGPoint(x: 0.2, y: 0.4), scale: 2, source: .manual)],
            base: left,
            path: path
        )
        let held = zoomed.cropRect(at: 8)
        #expect(isClose(held.x, 0.5) && isClose(held.width, 0.2))
        #expect(isClose(zoomed.scale(at: 8), 2))
        // Without a crop there's nothing to move.
        #expect(ZoomInterpolator(keyframes: [], path: path).cropRect(at: 8) == .fullFrame)
    }

    @Test func isSavedWithTheCropAndKeepsItsShape() throws {
        var settings = ProjectEditSettings()
        settings.sourceCrop = left
        settings.cropPath = CropPath(points: [CropPath.Point(time: 1, rect: left), CropPath.Point(time: 2, rect: right)], app: "Acme")
        let decoded = try JSONDecoder().decode(ProjectEditSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)

        // A path of another shape is fitted to the crop's; without a crop it's dropped.
        settings.cropPath = CropPath(points: [CropPath.Point(time: 2, rect: CGRect(x: 0.5, y: 0.2, width: 0.2, height: 0.5)), CropPath.Point(time: 1, rect: left)])
        let fitted = try JSONDecoder().decode(ProjectEditSettings.self, from: JSONEncoder().encode(settings))
        let points = try #require(fitted.cropPath?.points)
        #expect(points.map(\.time) == [1, 2])
        #expect(isClose(points[1].rect, CGRect(x: 0.4, y: 0.2, width: 0.4, height: 0.5)))
        settings.sourceCrop = nil
        let uncropped = try JSONDecoder().decode(ProjectEditSettings.self, from: JSONEncoder().encode(settings))
        #expect(uncropped.cropPath == nil)
        #expect(isClose(uncropped.cropBase(at: 1), SourceCrop.full))
    }
}
