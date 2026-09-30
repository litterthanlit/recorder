import CoreGraphics
import Foundation
import Testing
@testable import RecorderCore

@Suite("Canvas layout")
struct CanvasLayoutTests {
    private let retinaSource = CGSize(width: 3024, height: 1964)

    @Test func sizesFollowAspectAndShortSide() {
        #expect(CanvasSpec(aspect: .widescreen, resolution: .hd1080).pixelSize(source: retinaSource) == CGSize(width: 1920, height: 1080))
        #expect(CanvasSpec(aspect: .portrait, resolution: .hd1080).pixelSize(source: retinaSource) == CGSize(width: 1080, height: 1920))
        #expect(CanvasSpec(aspect: .square, resolution: .hd720).pixelSize(source: retinaSource) == CGSize(width: 720, height: 720))
        #expect(CanvasSpec(aspect: .vertical, resolution: .hd1080).pixelSize(source: retinaSource) == CGSize(width: 1080, height: 1350))
        #expect(CanvasSpec(aspect: .standard, resolution: .qhd1440).pixelSize(source: retinaSource) == CGSize(width: 1920, height: 1440))
        #expect(CanvasSpec(aspect: .widescreen, resolution: .uhd2160).pixelSize(source: retinaSource) == CGSize(width: 3840, height: 2160))
    }

    @Test func autoKeepsTheRecordingsShape() {
        let size = CanvasSpec(aspect: .auto, resolution: .hd1080).pixelSize(source: retinaSource)
        #expect(size.height == 1080)
        #expect(size.width == 1662)
        #expect(CanvasSpec(aspect: .auto, resolution: .source).pixelSize(source: CGSize(width: 1601, height: 901)) == CGSize(width: 1600, height: 900))
        // Source resolution with a fixed shape uses the recording's shorter side.
        #expect(CanvasSpec(aspect: .widescreen, resolution: .source).pixelSize(source: retinaSource).height == 1964)
    }

    @Test func verticalFourKStillUsesH264() {
        let size = CanvasSpec(aspect: .portrait, resolution: .uhd2160).pixelSize(source: retinaSource)
        #expect(size == CGSize(width: 2160, height: 3840))
        #expect(VideoCodecChoice.forFrame(width: Int(size.width), height: Int(size.height)) == .h264)
    }

    @Test func oldPresetsMigrate() {
        #expect(CanvasSpec.migrated(from: .source) == CanvasSpec(aspect: .auto, resolution: .source))
        #expect(CanvasSpec.migrated(from: .hd1080p) == CanvasSpec(aspect: .widescreen, resolution: .hd1080))
        #expect(CanvasSpec.migrated(from: .hd720p) == CanvasSpec(aspect: .widescreen, resolution: .hd720))
    }

    @Test func referenceUnitScalesWithTheShortSide() {
        #expect(isClose(CanvasLayout.referenceUnit(for: CGSize(width: 1920, height: 1080)), 1))
        #expect(isClose(CanvasLayout.referenceUnit(for: CGSize(width: 1080, height: 1920)), 1))
        #expect(isClose(CanvasLayout.referenceUnit(for: CGSize(width: 3840, height: 2160)), 2))
        #expect(isClose(CanvasLayout.referenceUnit(for: CGSize(width: 960, height: 540)), 0.5))
    }

    @Test func contentFitsInsideThePadding() {
        // 16:9 recording on a 9:16 canvas with 10% padding: width-limited.
        let frame = CanvasLayout.contentFrame(
            canvas: CGSize(width: 1080, height: 1920),
            contentAspect: 16.0 / 9.0,
            paddingRatio: 0.1
        )
        #expect(isClose(frame.minX, 108))
        #expect(isClose(frame.width, 864))
        #expect(isClose(frame.height, 486))
        #expect(isClose(frame.midY, 960))
    }

    @Test func paddingFromOldProjectsCarriesOver() throws {
        let style = try JSONDecoder().decode(ExportStyle.self, from: Data(#"{ "paddingFraction": 0.06 }"#.utf8))
        #expect(isClose(style.paddingRatio, 0.06 * 16 / 9, tolerance: 1e-9))
        let fresh = try JSONDecoder().decode(ExportStyle.self, from: Data("{}".utf8))
        #expect(isClose(fresh.paddingRatio, ExportStyle().paddingRatio))
    }

    @Test func settingsMigrateTheResolutionPreset() throws {
        let settings = try JSONDecoder().decode(ProjectEditSettings.self, from: Data(#"{ "exportPreset": "hd720p" }"#.utf8))
        #expect(settings.canvas == CanvasSpec(aspect: .widescreen, resolution: .hd720))
        let unknown = try JSONDecoder().decode(ProjectEditSettings.self, from: Data(#"{ "canvas": { "aspect": "cinema" } }"#.utf8))
        #expect(unknown.canvas.aspect == .auto)
    }
}
