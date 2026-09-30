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
        #expect(settings.exportPreset == .hd720p)
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
