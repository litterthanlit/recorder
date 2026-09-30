import CoreGraphics
import Foundation
import Testing
@testable import RecorderCore

@Suite("Project model")
struct ProjectModelTests {
    /// settings.json as written by the first release: no camera, no zoom preset.
    private let legacySettingsJSON = """
    {
      "exportPreset" : "hd720p",
      "exportStyle" : {
        "backgroundEnabled" : false,
        "watermarkEnabled" : true,
        "watermarkText" : "example.com"
      },
      "trimEnd" : 12.5,
      "trimStart" : 1.25
    }
    """

    /// meta.json from before window capture existed.
    private let legacyMetaJSON = """
    {
      "captureHeight" : 1117,
      "captureOriginX" : 0,
      "captureOriginY" : 0,
      "captureWidth" : 1728,
      "createdAt" : "2026-05-01T10:00:00Z",
      "duration" : 42.5,
      "fps" : 60,
      "height" : 2234,
      "id" : "8C1F7E36-2F0B-4B79-9D8E-1B7C44A8F001",
      "scaleFactor" : 2,
      "width" : 3456
    }
    """

    @Test func legacySettingsDecodeWithDefaults() throws {
        let settings = try JSONDecoder().decode(ProjectEditSettings.self, from: Data(legacySettingsJSON.utf8))
        #expect(isClose(settings.trimStart, 1.25))
        #expect(settings.trimEnd == 12.5)
        #expect(settings.canvas == CanvasSpec(aspect: .widescreen, resolution: .hd720))
        #expect(settings.zoomPreset == .demo)
        #expect(settings.camera == CameraOverlayStyle())
        #expect(settings.exportStyle.backgroundEnabled == false)
        #expect(settings.exportStyle.watermarkEnabled)
        #expect(settings.exportStyle.watermarkText == "example.com")
        // Fields the old file didn't have fall back to today's defaults.
        #expect(settings.exportStyle.springCameraEnabled)
        #expect(isClose(settings.exportStyle.cornerRadius, 16))
    }

    @Test func emptySettingsDecodeToDefaults() throws {
        let settings = try JSONDecoder().decode(ProjectEditSettings.self, from: Data("{}".utf8))
        #expect(settings == ProjectEditSettings())
    }

    @Test func legacyMetadataDefaultsToDisplayCapture() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(ProjectMetadata.self, from: Data(legacyMetaJSON.utf8))
        #expect(metadata.captureTarget == .display)
        #expect(metadata.windowTitle == nil)
        #expect(metadata.width == 3456)
        #expect(isClose(metadata.duration, 42.5))
    }

    @Test func partialPreferencesKeepSavedValues() throws {
        let json = """
        { "countdownSeconds" : 5, "microphoneEnabled" : true, "cameraBackground" : "blur" }
        """
        let preferences = try JSONDecoder().decode(RecordingPreferences.self, from: Data(json.utf8))
        #expect(preferences.countdownSeconds == 5)
        #expect(preferences.microphoneEnabled)
        #expect(preferences.cameraBackground == .blur)
        #expect(preferences.captureTarget == RecordingPreferences.default.captureTarget)
        #expect(preferences.hideChromeDuringRecording == RecordingPreferences.default.hideChromeDuringRecording)
    }

    @Test func saveAndLoadRoundTrip() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }

        let project = Self.sampleProject()
        let bundleURL = ProjectStore.bundleURL(for: project.metadata.id, in: directory.url)
        try ProjectStore.save(project, to: bundleURL)

        let loaded = try ProjectStore.loadProject(from: bundleURL)
        #expect(loaded == project)
    }

    @Test func listSkipsDamagedBundlesAndSortsNewestFirst() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }

        let older = Self.sampleProject(createdAt: Date(timeIntervalSince1970: 1_000))
        let newer = Self.sampleProject(createdAt: Date(timeIntervalSince1970: 2_000))
        try ProjectStore.save(older, to: ProjectStore.bundleURL(for: older.metadata.id, in: directory.url))
        try ProjectStore.save(newer, to: ProjectStore.bundleURL(for: newer.metadata.id, in: directory.url))
        // A bundle without meta.json, a damaged one, and an unrelated folder.
        try directory.write("{}", to: "\(UUID().uuidString).recorder/settings.json")
        try directory.write("not json", to: "\(UUID().uuidString).recorder/meta.json")
        try directory.write("{}", to: "Other/meta.json")

        let summaries = ProjectStore.listProjects(in: directory.url)
        #expect(summaries.map(\.id) == [newer.metadata.id, older.metadata.id])
        #expect(ProjectStore.listProjects(in: directory.url, limit: 1).map(\.id) == [newer.metadata.id])
    }

    static func sampleProject(createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> RecorderProject {
        let metadata = ProjectMetadata(
            id: UUID(),
            createdAt: createdAt,
            width: 1920,
            height: 1080,
            fps: 60,
            duration: 10,
            scaleFactor: 2,
            captureOriginX: 0,
            captureOriginY: 0,
            captureWidth: 960,
            captureHeight: 540,
            captureTarget: .window,
            windowTitle: "Docs",
            appName: "Safari"
        )
        var settings = ProjectEditSettings()
        settings.trimStart = 0.5
        settings.trimEnd = 9
        return RecorderProject(
            metadata: metadata,
            clickEvents: [ClickEvent(timestamp: 1, location: CGPoint(x: 10, y: 20), button: .left)],
            cursorEvents: [CursorEvent(timestamp: 1, location: CGPoint(x: 10, y: 20))],
            keyframes: [
                ZoomKeyframe(startTime: 0.5, peakTime: 1, endTime: 2.5, center: CGPoint(x: 0.5, y: 0.5), scale: 1.6)
            ],
            editSettings: settings
        )
    }
}

@Suite("Project format version")
struct ProjectFormatTests {
    @Test func savingWritesTheCurrentVersion() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let project = ProjectModelTests.sampleProject()
        let bundleURL = ProjectStore.bundleURL(for: project.metadata.id, in: directory.url)
        try ProjectStore.save(project, to: bundleURL)

        for file in [ProjectStore.File.meta, ProjectStore.File.settings] {
            let data = try Data(contentsOf: bundleURL.appendingPathComponent(file))
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["formatVersion"] as? Int == ProjectFormat.current)
        }
        // The version key sits next to the value's own keys.
        let settings = try JSONSerialization.jsonObject(
            with: Data(contentsOf: bundleURL.appendingPathComponent(ProjectStore.File.settings))
        ) as? [String: Any]
        #expect(settings?["trimStart"] as? Double == 0.5)
    }

    @Test func filesWithoutAVersionLoad() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let project = ProjectModelTests.sampleProject()
        let bundleURL = ProjectStore.bundleURL(for: project.metadata.id, in: directory.url)
        try ProjectStore.save(project, to: bundleURL)
        try Self.rewrite(bundleURL.appendingPathComponent(ProjectStore.File.settings)) { $0["formatVersion"] = nil }

        #expect(try ProjectStore.loadProject(from: bundleURL) == project)
    }

    @Test func newerFormatsAreRefused() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let project = ProjectModelTests.sampleProject()
        let bundleURL = ProjectStore.bundleURL(for: project.metadata.id, in: directory.url)
        try ProjectStore.save(project, to: bundleURL)
        try Self.rewrite(bundleURL.appendingPathComponent(ProjectStore.File.settings)) { $0["formatVersion"] = 99 }

        #expect(throws: ProjectStoreError.newerFormat(99)) {
            try ProjectStore.loadProject(from: bundleURL)
        }

        try Self.rewrite(bundleURL.appendingPathComponent(ProjectStore.File.meta)) { $0["formatVersion"] = 99 }
        #expect(ProjectStore.listProjects(in: directory.url).isEmpty)
    }

    private static func rewrite(_ url: URL, _ change: (inout [String: Any]) -> Void) throws {
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        change(&object)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }
}

@Suite("Edit settings migration")
struct EditSettingsMigrationTests {
    @Test func oldTrimBecomesTheTimeline() throws {
        let json = #"{ "trimStart": 1.5, "trimEnd": 8 }"#
        let settings = try JSONDecoder().decode(ProjectEditSettings.self, from: Data(json.utf8))
        #expect(settings.timeline == nil)
        let timeline = settings.resolvedTimeline(sourceDuration: 10)
        #expect(timeline.segments.count == 1)
        #expect(isClose(timeline.trimStart, 1.5) && isClose(timeline.trimEnd, 8))
    }

    @Test func savedTimelineWinsAndKeepsLegacyTrimInStep() throws {
        var settings = ProjectEditSettings()
        var timeline = EditTimeline(sourceDuration: 10)
        timeline.split(atOutput: 4)
        timeline.setTrimStart(1)
        settings.setTimeline(timeline)
        #expect(isClose(settings.trimStart, 1))
        #expect(settings.trimEnd == 10)

        let data = try JSONEncoder().encode(settings)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["trimStart"] as? Double == 1)
        let decoded = try JSONDecoder().decode(ProjectEditSettings.self, from: data)
        #expect(decoded == settings)
        #expect(decoded.resolvedTimeline(sourceDuration: 10).segments.count == 2)
    }

    @Test func audioLevelsDecodeWithDefaultsAndClamp() throws {
        let settings = try JSONDecoder().decode(ProjectEditSettings.self, from: Data(#"{ "audio": { "systemAudioVolume": 5 } }"#.utf8))
        #expect(settings.audio.microphoneVolume == 1)
        #expect(settings.audio.volume(for: .systemAudio) == 2)
    }

    @Test func legacyAudioTracksAreMicThenSystem() {
        let metadata = ProjectModelTests.sampleProject().metadata
        #expect(metadata.resolvedAudioTrackRoles(trackCount: 0).isEmpty)
        #expect(metadata.resolvedAudioTrackRoles(trackCount: 1) == [.microphone])
        #expect(metadata.resolvedAudioTrackRoles(trackCount: 2) == [.microphone, .systemAudio])
    }
}

@Suite("Library")
struct LibraryTests {
    @Test func renamingRewritesOnlyTheName() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let project = ProjectModelTests.sampleProject()
        let bundleURL = ProjectStore.bundleURL(for: project.metadata.id, in: directory.url)
        try ProjectStore.save(project, to: bundleURL)

        try ProjectStore.rename(bundleURL: bundleURL, to: "  Onboarding demo ")
        var summary = try #require(ProjectStore.listProjects(in: directory.url).first)
        #expect(summary.name == "Onboarding demo")
        #expect(summary.displayName == "Onboarding demo")
        #expect(try ProjectStore.loadProject(from: bundleURL).clickEvents == project.clickEvents)

        try ProjectStore.rename(bundleURL: bundleURL, to: "")
        summary = try #require(ProjectStore.listProjects(in: directory.url).first)
        #expect(summary.name == nil)
        #expect(summary.displayName == "Safari — Docs")
    }

    @Test func searchMatchesNameAndDescription() {
        var metadata = ProjectModelTests.sampleProject().metadata
        metadata.name = "Pricing Page Walkthrough"
        let summary = ProjectSummary(metadata: metadata, bundleURL: URL(fileURLWithPath: "/tmp/x.recorder"))
        #expect(summary.matches("pricing"))
        #expect(summary.matches("SAFARI"))
        #expect(summary.matches(""))
        #expect(!summary.matches("keynote"))
    }

    @Test func sortsByEachOrder() {
        func summary(_ name: String, created: TimeInterval, duration: TimeInterval) -> ProjectSummary {
            let base = ProjectModelTests.sampleProject(createdAt: Date(timeIntervalSince1970: created)).metadata
            var metadata = ProjectMetadata(
                id: UUID(), createdAt: base.createdAt, width: 10, height: 10, fps: 60, duration: duration,
                scaleFactor: 2, captureOriginX: 0, captureOriginY: 0, captureWidth: 5, captureHeight: 5
            )
            metadata.name = name
            return ProjectSummary(metadata: metadata, bundleURL: URL(fileURLWithPath: "/tmp/\(name).recorder"))
        }
        let projects = [summary("b", created: 2, duration: 5), summary("a", created: 3, duration: 1), summary("c", created: 1, duration: 9)]
        #expect(ProjectSort.newest.sorted(projects).map(\.displayName) == ["a", "b", "c"])
        #expect(ProjectSort.oldest.sorted(projects).map(\.displayName) == ["c", "b", "a"])
        #expect(ProjectSort.longest.sorted(projects).map(\.displayName) == ["c", "b", "a"])
        #expect(ProjectSort.name.sorted(projects).map(\.displayName) == ["a", "b", "c"])
    }
}
