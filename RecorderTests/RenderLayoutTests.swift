import CoreGraphics
import Foundation
import Testing
@testable import RecorderCore

@Suite("Render layout")
struct RenderLayoutTests {
    @Test func gradientAnglesWorkLikeCSS() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
        let right = BackgroundStyle.gradientEndpoints(angle: 90, in: rect)
        #expect(isClose(right.start.x, 0, tolerance: 1e-6) && isClose(right.start.y, 50, tolerance: 1e-6))
        #expect(isClose(right.end.x, 200, tolerance: 1e-6) && isClose(right.end.y, 50, tolerance: 1e-6))

        // 180° runs top to bottom; Core Image is y-up, so it starts at the top edge.
        let down = BackgroundStyle.gradientEndpoints(angle: 180, in: rect)
        #expect(isClose(down.start.y, 100, tolerance: 1e-6) && isClose(down.end.y, 0, tolerance: 1e-6))

        // 135° starts beyond the top-left corner and ends beyond the bottom-right one.
        let diagonal = BackgroundStyle.gradientEndpoints(angle: 135, in: rect)
        #expect(diagonal.start.x < 0 && diagonal.start.y > 100)
        #expect(diagonal.end.x > 200 && diagonal.end.y < 0)
    }

    @Test func textStaysOnTheCanvas() {
        let canvas = CGSize(width: 1920, height: 1080)
        let size = CGSize(width: 400, height: 100)
        let centered = OverlayLayout.centeredFrame(size: size, normalizedCenter: CGPoint(x: 0.5, y: 0.5), canvas: canvas, margin: 16)
        #expect(isClose(centered, CGRect(x: 760, y: 490, width: 400, height: 100)))

        // Normalized y is top-left based: 0.1 is near the top, which is high in y-up space.
        let nearTop = OverlayLayout.centeredFrame(size: size, normalizedCenter: CGPoint(x: 0.5, y: 0.1), canvas: canvas, margin: 16)
        #expect(nearTop.midY > 900)

        let offCorner = OverlayLayout.centeredFrame(size: size, normalizedCenter: CGPoint(x: 1, y: 1), canvas: canvas, margin: 16)
        #expect(isClose(offCorner, CGRect(x: 1504, y: 16, width: 400, height: 100)))
    }

    @Test func keystrokesSitOnTheRecording() {
        let content = CGRect(x: 100, y: 50, width: 800, height: 450)
        let size = CGSize(width: 120, height: 40)
        let bottom = OverlayLayout.keystrokeOrigin(size: size, contentFrame: content, placement: .bottom, margin: 20)
        #expect(isClose(bottom.x, 440) && isClose(bottom.y, 70))
        let top = OverlayLayout.keystrokeOrigin(size: size, contentFrame: content, placement: .top, margin: 20)
        #expect(isClose(top.y, 440))
    }

    @Test func cameraSliderSizeMatchesThePresets() {
        let bounds = CGSize(width: 1600, height: 900)
        let preset = CameraBubbleLayout.frame(in: bounds, position: .bottomRight, size: .large)
        let slider = CameraBubbleLayout.frame(in: bounds, position: .bottomRight, diameterFraction: CameraBubbleSize.large.diameterFraction)
        #expect(isClose(preset, slider))

        // Never bigger than the frame minus its padding.
        let huge = CameraBubbleLayout.frame(in: bounds, position: .topLeft, diameterFraction: 5)
        #expect(huge.height <= 900 - 900 * CameraBubbleLayout.paddingFraction * 2 + 1e-6)
        #expect(huge.minY >= 0)
    }

    @Test func cameraMotionMeasuresPansAndZooms() throws {
        let size = CGSize(width: 1000, height: 500)
        let still = CameraMotion.between(
            NormalizedRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5),
            NormalizedRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5),
            contentSize: size
        )
        #expect(isClose(still.pan.dx, 0) && isClose(still.zoom, 0) && still.zoomAnchor == nil)

        // The crop moves right by a tenth of its width: the picture slides left 100 px.
        let pan = CameraMotion.between(
            NormalizedRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5),
            NormalizedRect(x: 0.25, y: 0.2, width: 0.5, height: 0.5),
            contentSize: size
        )
        #expect(isClose(pan.pan.dx, -100, tolerance: 1e-6))
        #expect(isClose(pan.pan.dy, 0, tolerance: 1e-6))

        // Zooming in 2x about the centre keeps the centre still.
        let zoom = CameraMotion.between(
            NormalizedRect(x: 0, y: 0, width: 1, height: 1),
            NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            contentSize: size
        )
        #expect(isClose(zoom.zoom, 1, tolerance: 1e-6))
        let anchor = try #require(zoom.zoomAnchor)
        #expect(isClose(anchor.x, 0.5, tolerance: 1e-6) && isClose(anchor.y, 0.5, tolerance: 1e-6))
    }

    @Test func idleActivityIgnoresJitter() {
        let cursor = [
            CursorEvent(timestamp: 0, location: CGPoint(x: 10, y: 10)),
            CursorEvent(timestamp: 0.5, location: CGPoint(x: 10.4, y: 10.2)),
            CursorEvent(timestamp: 1, location: CGPoint(x: 40, y: 10)),
            CursorEvent(timestamp: 2, location: CGPoint(x: 40, y: 10))
        ]
        let clicks = [ClickEvent(timestamp: 1.5, location: CGPoint(x: 40, y: 10), button: .left)]
        let times = CursorVisibility.activityTimes(cursor: cursor, clicks: clicks)
        #expect(times == [0, 1, 1.5])
    }
}

@Suite("Style library")
struct StyleLibraryTests {
    @Test func savingReplacesAndDeletingClearsTheDefault() {
        var library = StyleLibrary()
        var preset = StylePreset(name: "Launch")
        library.save(preset)
        preset.name = "Launch v2"
        library.save(preset)
        #expect(library.presets.map(\.name) == ["Launch v2"])

        // Built-in looks stay as they are.
        library.save(StylePreset.builtIn[0])
        #expect(library.presets.count == 1)

        library.defaultPresetID = preset.id
        library.delete(id: preset.id)
        #expect(library.presets.isEmpty)
        #expect(library.defaultPresetID == nil)
    }

    @Test func aDamagedPresetDoesNotLoseTheOthers() throws {
        let good = StylePreset(name: "Good")
        let goodJSON = String(decoding: try JSONEncoder().encode(good), as: UTF8.self)
        let json = #"{ "presets": [\#(goodJSON), { "id": 42 }], "defaultPresetID": "\#(good.id.uuidString)" }"#
        let library = try JSONDecoder().decode(StyleLibrary.self, from: Data(json.utf8))
        #expect(library.presets.map(\.name) == ["Good"])
        #expect(library.defaultPreset?.name == "Good")
    }

    @Test func storeRoundTripsAndToleratesAMissingFile() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let url = directory.url.appendingPathComponent("Trace/styles.json")
        #expect(StyleLibraryStore.load(from: url) == StyleLibrary())

        let preset = StylePreset(name: "Mine")
        let library = StyleLibrary(presets: [preset], defaultPresetID: preset.id)
        try StyleLibraryStore.save(library, to: url)
        #expect(StyleLibraryStore.load(from: url) == library)

        try Data("garbage".utf8).write(to: url)
        #expect(StyleLibraryStore.load(from: url) == StyleLibrary())
    }

    @Test func newTakesUseTheDefaultLookAndTheRecordingChoices() {
        var look = StylePreset.builtIn.first { $0.name == "Studio Light" }!
        look.camera.customSize = 0.3
        look.camera.shape = .roundedSquare
        let timeline = EditTimeline(sourceDuration: 12)
        let settings = ProjectEditSettings.forNewTake(
            timeline: timeline,
            look: look,
            cursorSmoothing: false,
            cameraPosition: .topLeft,
            cameraSize: .small
        )
        #expect(settings.exportStyle.background.wallpaper == .snow)
        #expect(settings.zoomPreset == .subtle)
        #expect(settings.camera.shape == .roundedSquare)
        #expect(settings.camera.position == .topLeft)
        #expect(settings.camera.customSize == nil)
        #expect(isClose(settings.camera.diameterFraction, CameraBubbleSize.small.diameterFraction))
        #expect(!settings.exportStyle.cursorSmoothingEnabled)
        #expect(isClose(settings.trimEnd ?? 0, 12))

        let plain = ProjectEditSettings.forNewTake(
            timeline: timeline,
            look: nil,
            cursorSmoothing: true,
            cameraPosition: .bottomRight,
            cameraSize: .medium
        )
        #expect(plain.exportStyle.background == ExportStyle().background)
    }
}

@Suite("Background images")
struct BackgroundImageTests {
    @Test func importedImagesLiveInTheBundle() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        try directory.write("png bytes", to: "Pictures/Wall.PNG")
        try directory.write("{}", to: "Project.recorder/meta.json")
        let bundle = directory.url.appendingPathComponent("Project.recorder")

        let name = try ProjectStore.importBackgroundImage(
            from: directory.url.appendingPathComponent("Pictures/Wall.PNG"),
            into: bundle
        )
        #expect(name.hasPrefix("background-") && name.hasSuffix(".png"))
        #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent(name).path))

        let second = try ProjectStore.importBackgroundImage(
            from: directory.url.appendingPathComponent("Pictures/Wall.PNG"),
            into: bundle
        )
        ProjectStore.removeUnusedBackgroundImages(in: bundle, keeping: second)
        #expect(!FileManager.default.fileExists(atPath: bundle.appendingPathComponent(name).path))
        #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent(second).path))
        #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("meta.json").path))
    }

    @Test func onlyImportedNamesResolve() {
        var project = ProjectModelTests.sampleProject()
        project.editSettings.exportStyle.background.kind = .image
        project.editSettings.exportStyle.background.imageFileName = "background-1234.png"
        #expect(project.backgroundImageURL?.lastPathComponent == "background-1234.png")

        project.editSettings.exportStyle.background.imageFileName = "../../secrets.png"
        #expect(project.backgroundImageURL == nil)
        project.editSettings.exportStyle.background.imageFileName = "background-1234.png"
        project.editSettings.exportStyle.background.kind = .wallpaper
        #expect(project.backgroundImageURL == nil)
    }
}
