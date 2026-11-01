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
        let bytes = ExportOptions(format: .mp4).plan(canvas: size, sourceFrameRate: 60, duration: 10).estimatedBytes ?? 0
        #expect(bytes > 10_000_000 && bytes < 20_000_000)
        #expect(ExportOptions(format: .gif).plan(canvas: size, sourceFrameRate: 60, duration: 10).estimatedBytes == nil)
        let prores = ExportOptions(format: .prores).plan(canvas: size, sourceFrameRate: 30, duration: 10).estimatedBytes ?? 0
        #expect(prores > bytes)
    }

    @Test func withoutALimitThePlanFollowsTheQuality() {
        let canvas = CGSize(width: 1920, height: 1080)
        let options = ExportOptions(format: .mp4, quality: .high)
        let plan = options.plan(canvas: canvas, sourceFrameRate: 60, duration: 600)
        #expect(plan.size == canvas)
        #expect(plan.frameRate == 60)
        #expect(plan.videoBitrate == options.bitrate(size: canvas, fps: 60))
        #expect(plan.audioBitrate == ExportOptions.audioBitrate)
        #expect(!plan.exceedsSizeLimit)
    }

    @Test func aShortEditFitsAtFullSizeAndQuality() {
        let canvas = CGSize(width: 1920, height: 1080)
        let options = ExportOptions(format: .mp4, quality: .high, maxMegabytes: 25)
        let plan = options.plan(canvas: canvas, sourceFrameRate: 60, duration: 5)
        #expect(plan.size == canvas)
        #expect(plan.frameRate == 60)
        // Never more than the quality asks for, even with room to spare.
        #expect(plan.videoBitrate == options.bitrate(size: canvas, fps: 60))
    }

    @Test func aLongerEditShrinksToStayUnderTheLimit() {
        let canvas = CGSize(width: 1920, height: 1080)
        let plan = ExportOptions(format: .mp4, quality: .high, maxMegabytes: 25)
            .plan(canvas: canvas, sourceFrameRate: 60, duration: 180)
        #expect(plan.size.height < canvas.height)
        #expect(plan.frameRate == 30)
        #expect(Int(plan.size.width) % 2 == 0 && Int(plan.size.height) % 2 == 0)
        #expect(isClose(plan.size.width / plan.size.height, canvas.width / canvas.height, tolerance: 0.01))
        #expect(!plan.exceedsSizeLimit)
        #expect((plan.estimatedBytes ?? .max) <= 25_000_000)
    }

    @Test func editsUpToFiveMinutesFitTwentyFiveMegabytes() {
        let canvases = [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920), CGSize(width: 2560, height: 1440)]
        for format in [ExportFormat.mp4, .hevc] {
            for canvas in canvases {
                var previousPixels = CGFloat.infinity
                for seconds in stride(from: 1.0, through: 300, by: 7) {
                    let plan = ExportOptions(format: format, quality: .studio, maxMegabytes: 25)
                        .plan(canvas: canvas, sourceFrameRate: 60, duration: seconds)
                    let bytes = plan.estimatedBytes ?? .max
                    #expect(!plan.exceedsSizeLimit, "\(format) \(canvas) \(seconds) s")
                    #expect(bytes <= 25_000_000, "\(format) \(canvas) \(seconds) s: \(bytes) bytes")
                    // Longer edits never get a bigger picture than shorter ones.
                    let pixels = plan.size.width * plan.size.height
                    #expect(pixels <= previousPixels)
                    previousPixels = pixels
                }
            }
        }
    }

    @Test func anEditTooLongForTheLimitIsFlagged() {
        let canvas = CGSize(width: 1920, height: 1080)
        let plan = ExportOptions(format: .mp4, maxMegabytes: 10).plan(canvas: canvas, sourceFrameRate: 60, duration: 3_600)
        #expect(plan.exceedsSizeLimit)
        #expect(plan.size == CGSize(width: 640, height: 360))
        #expect(plan.frameRate == 30)
    }

    @Test func theLimitOnlyAppliesToCompressedFormats() {
        let canvas = CGSize(width: 1920, height: 1080)
        let prores = ExportOptions(format: .prores, maxMegabytes: 10).plan(canvas: canvas, sourceFrameRate: 30, duration: 60)
        #expect(prores.size == canvas)
        #expect(prores.sizeLimitBytes == nil)
        #expect(!ExportOptions(format: .gif, maxMegabytes: 10).usesSizeLimit)
        #expect(ExportOptions(format: .hevc, maxMegabytes: 10).usesSizeLimit)
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
        #expect(options.maxMegabytes == nil)

        let limited = try JSONDecoder().decode(ExportOptions.self, from: Data(#"{ "maxMegabytes": 25 }"#.utf8))
        #expect(limited.maxMegabytes == 25)
        let negative = try JSONDecoder().decode(ExportOptions.self, from: Data(#"{ "maxMegabytes": -3 }"#.utf8))
        #expect(negative.maxMegabytes == nil)

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
