import CoreGraphics
import Foundation
import Testing
@testable import RecorderCore

@Suite("Export options")
struct ExportOptionsTests {
    @Test func frameRateFollowsTheChoice() {
        #expect(ExportOptions().outputFrameRate(source: 60) == 60)
        #expect(ExportOptions(frameRate: 30).outputFrameRate(source: 60) == 30)
        #expect(ExportOptions(format: .gif, frameRate: 60).outputFrameRate(source: 60) == ExportOptions.gifFrameRate)
    }

    @Test func gifsAreScaledDown() {
        let canvas = CGSize(width: 1920, height: 1080)
        #expect(ExportOptions().outputSize(canvas: canvas) == canvas)
        let gif = ExportOptions(format: .gif).outputSize(canvas: canvas)
        #expect(isClose(gif.width, ExportOptions.gifMaximumWidth))
        #expect(isClose(gif.height, 404))
        #expect(Int(gif.height) % 2 == 0)
        let small = CGSize(width: 640, height: 360)
        #expect(ExportOptions(format: .gif).outputSize(canvas: small) == small)
    }

    @Test func bitratesAndSizes() {
        let size = CGSize(width: 1920, height: 1080)
        let h264 = ExportOptions(format: .mp4, quality: .high).bitrate(size: size, fps: 60)
        let hevc = ExportOptions(format: .hevc, quality: .high).bitrate(size: size, fps: 60)
        let web = ExportOptions(format: .mp4, quality: .web).bitrate(size: size, fps: 60)
        #expect(hevc < h264)
        #expect(web < h264)
        let bytes = ExportOptions(format: .mp4).estimatedBytes(size: size, fps: 60, duration: 10) ?? 0
        #expect(bytes > 10_000_000 && bytes < 20_000_000)
        #expect(ExportOptions(format: .gif).estimatedBytes(size: size, fps: 15, duration: 10) == nil)
        let prores = ExportOptions(format: .prores).estimatedBytes(size: size, fps: 30, duration: 10) ?? 0
        #expect(prores > bytes)
    }

    @Test func longEditsCantBeGIFs() {
        #expect(ExportOptions.allows(.gif, duration: 20))
        #expect(!ExportOptions.allows(.gif, duration: 45))
        #expect(ExportOptions.allows(.mp4, duration: 3_600))
    }

    @Test func decodingIsTolerant() throws {
        let json = #"{ "format": "webm", "quality": "ultra", "frameRate": 25 }"#
        let options = try JSONDecoder().decode(ExportOptions.self, from: Data(json.utf8))
        #expect(options.format == .mp4)
        #expect(options.quality == .high)
        #expect(options.frameRate == nil)

        let preferences = try JSONDecoder().decode(ExportPreferences.self, from: Data("{}".utf8))
        #expect(preferences == ExportPreferences())
        #expect(preferences.folderURL == ProjectStore.exportsDirectory)
    }
}

@Suite("Export naming")
struct ExportNamingTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func templatesFillInNameDateAndTime() {
        let date = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21 14:13:20 UTC
        let name = ExportNaming.fileName(
            template: "{name} {date} at {time}",
            name: "Onboarding tour",
            date: date,
            fileExtension: "mp4",
            calendar: calendar
        )
        #expect(name == "Onboarding tour 2026-09-21 at 14.13.20.mp4")
        #expect(ExportNaming.baseName(template: "{name}", name: "Demo", date: date, calendar: calendar) == "Demo")
    }

    @Test func namesAreMadeSafe() {
        #expect(ExportNaming.sanitized("Chrome — a/b: c") == "Chrome — a b c")
        #expect(ExportNaming.sanitized("  ..hidden  ") == "hidden")
        #expect(ExportNaming.sanitized("line\nbreak") == "line break")
        #expect(ExportNaming.sanitized("///") == "Recording")
        #expect(ExportNaming.sanitized(String(repeating: "a", count: 300)).count == 120)
    }

    @Test func existingFilesAreNeverReplaced() {
        let folder = URL(fileURLWithPath: "/tmp/exports", isDirectory: true)
        let taken: Set<String> = ["Demo.mp4", "Demo 2.mp4"]
        let url = ExportNaming.uniqueURL(in: folder, fileName: "Demo.mp4") { taken.contains($0.lastPathComponent) }
        #expect(url.lastPathComponent == "Demo 3.mp4")
        let free = ExportNaming.uniqueURL(in: folder, fileName: "Other.gif") { taken.contains($0.lastPathComponent) }
        #expect(free.lastPathComponent == "Other.gif")
    }
}

@Suite("GIF timing")
struct GIFTimingTests {
    @Test func delaysKeepTheTotalInStep() {
        let delays = GIFTiming.delays(frameCount: 15, fps: 15)
        #expect(delays.count == 15)
        #expect(delays.reduce(0, +) == 100)
        #expect(Set(delays).isSubset(of: [6, 7]))
        #expect(GIFTiming.delays(frameCount: 10, fps: 10) == Array(repeating: 10, count: 10))
    }

    @Test func delaysNeverDropBelowWhatBrowsersHonor() {
        #expect(GIFTiming.delays(frameCount: 5, fps: 100).allSatisfy { $0 >= 2 })
        #expect(GIFTiming.delays(frameCount: 0, fps: 15).isEmpty)
    }
}

@Suite("Export records")
struct ExportRecordTests {
    @Test func theLatestExportIsRememberedWhileItsFileExists() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        try directory.write("{}", to: "Take.recorder/meta.json")
        let bundle = directory.url.appendingPathComponent("Take.recorder")
        #expect(ProjectStore.latestExport(in: bundle) == nil)

        try directory.write("old", to: "Take.recorder/export.mp4")
        #expect(ProjectStore.latestExport(in: bundle)?.lastPathComponent == "export.mp4")

        try directory.write("new", to: "Exports/Take.mp4")
        let exported = directory.url.appendingPathComponent("Exports/Take.mp4")
        try ProjectStore.saveExportRecord(ExportRecord(path: exported.path, format: .mp4, date: Date()), in: bundle)
        #expect(ProjectStore.latestExport(in: bundle)?.path == exported.path)

        try FileManager.default.removeItem(at: exported)
        #expect(ProjectStore.latestExport(in: bundle)?.lastPathComponent == "export.mp4")
    }
}
