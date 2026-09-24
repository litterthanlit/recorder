import CoreGraphics
import Foundation

struct ProjectMetadata: Codable, Equatable {
    let id: UUID
    let createdAt: Date
    let width: Int
    let height: Int
    let fps: Int
    let duration: TimeInterval
    let scaleFactor: CGFloat
    let captureOriginX: CGFloat
    let captureOriginY: CGFloat
    let captureWidth: CGFloat
    let captureHeight: CGFloat
    let captureTarget: CaptureTargetKind
    let windowTitle: String?
    let appName: String?

    var captureOrigin: CGPoint {
        CGPoint(x: captureOriginX, y: captureOriginY)
    }

    init(
        id: UUID,
        createdAt: Date,
        width: Int,
        height: Int,
        fps: Int,
        duration: TimeInterval,
        scaleFactor: CGFloat,
        captureOriginX: CGFloat,
        captureOriginY: CGFloat,
        captureWidth: CGFloat,
        captureHeight: CGFloat,
        captureTarget: CaptureTargetKind = .display,
        windowTitle: String? = nil,
        appName: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.width = width
        self.height = height
        self.fps = fps
        self.duration = duration
        self.scaleFactor = scaleFactor
        self.captureOriginX = captureOriginX
        self.captureOriginY = captureOriginY
        self.captureWidth = captureWidth
        self.captureHeight = captureHeight
        self.captureTarget = captureTarget
        self.windowTitle = windowTitle
        self.appName = appName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
        fps = try container.decode(Int.self, forKey: .fps)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        scaleFactor = try container.decode(CGFloat.self, forKey: .scaleFactor)
        captureOriginX = try container.decode(CGFloat.self, forKey: .captureOriginX)
        captureOriginY = try container.decode(CGFloat.self, forKey: .captureOriginY)
        captureWidth = try container.decode(CGFloat.self, forKey: .captureWidth)
        captureHeight = try container.decode(CGFloat.self, forKey: .captureHeight)
        captureTarget = try container.decodeIfPresent(CaptureTargetKind.self, forKey: .captureTarget) ?? .display
        windowTitle = try container.decodeIfPresent(String.self, forKey: .windowTitle)
        appName = try container.decodeIfPresent(String.self, forKey: .appName)
    }
}

struct RecorderProject: Codable, Equatable {
    var metadata: ProjectMetadata
    var clickEvents: [ClickEvent]
    var cursorEvents: [CursorEvent]
    var keyframes: [ZoomKeyframe]
    var editSettings: ProjectEditSettings

    static let bundleExtension = "recorder"

    var bundleURL: URL {
        ProjectStore.projectsDirectory.appendingPathComponent("\(metadata.id.uuidString).\(Self.bundleExtension)")
    }

    var videoURL: URL {
        bundleURL.appendingPathComponent("video.mov")
    }

    var eventsURL: URL {
        bundleURL.appendingPathComponent("events.json")
    }

    var cursorURL: URL {
        bundleURL.appendingPathComponent("cursor.json")
    }

    var keyframesURL: URL {
        bundleURL.appendingPathComponent("keyframes.json")
    }

    var metaURL: URL {
        bundleURL.appendingPathComponent("meta.json")
    }

    var settingsURL: URL {
        bundleURL.appendingPathComponent("settings.json")
    }

    var exportURL: URL {
        bundleURL.appendingPathComponent("export.mp4")
    }

    static let cameraFileName = "camera.mov"

    /// Separately recorded camera track (projects recorded before this existed, or
    /// without the camera, don't have one).
    var cameraURL: URL {
        bundleURL.appendingPathComponent(Self.cameraFileName)
    }

    var hasCameraTrack: Bool {
        FileManager.default.fileExists(atPath: cameraURL.path)
    }

    init(
        metadata: ProjectMetadata,
        clickEvents: [ClickEvent],
        cursorEvents: [CursorEvent] = [],
        keyframes: [ZoomKeyframe],
        editSettings: ProjectEditSettings = ProjectEditSettings()
    ) {
        self.metadata = metadata
        self.clickEvents = clickEvents
        self.cursorEvents = cursorEvents
        self.keyframes = keyframes
        self.editSettings = editSettings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try container.decode(ProjectMetadata.self, forKey: .metadata)
        clickEvents = try container.decode([ClickEvent].self, forKey: .clickEvents)
        cursorEvents = try container.decodeIfPresent([CursorEvent].self, forKey: .cursorEvents) ?? []
        keyframes = try container.decode([ZoomKeyframe].self, forKey: .keyframes)
        editSettings = try container.decodeIfPresent(ProjectEditSettings.self, forKey: .editSettings) ?? ProjectEditSettings()
    }
}

enum ProjectStore {
    static var projectsDirectory: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        return movies.appendingPathComponent("Recorder", isDirectory: true)
    }

    static func ensureProjectsDirectory() throws {
        try FileManager.default.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
    }

    static func save(_ project: RecorderProject) throws {
        try ensureProjectsDirectory()
        try FileManager.default.createDirectory(at: project.bundleURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        try encoder.encode(project.metadata).write(to: project.metaURL)
        try encoder.encode(project.clickEvents).write(to: project.eventsURL)
        try encoder.encode(project.cursorEvents).write(to: project.cursorURL)
        try encoder.encode(project.keyframes).write(to: project.keyframesURL)
        try encoder.encode(project.editSettings).write(to: project.settingsURL)
    }

    static func loadMetadata(from bundleURL: URL) throws -> ProjectMetadata {
        let data = try Data(contentsOf: bundleURL.appendingPathComponent("meta.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ProjectMetadata.self, from: data)
    }

    static func loadEvents(from bundleURL: URL) throws -> [ClickEvent] {
        let data = try Data(contentsOf: bundleURL.appendingPathComponent("events.json"))
        return try JSONDecoder().decode([ClickEvent].self, from: data)
    }

    static func loadCursorEvents(from bundleURL: URL) throws -> [CursorEvent] {
        let url = bundleURL.appendingPathComponent("cursor.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([CursorEvent].self, from: data)
    }

    static func loadKeyframes(from bundleURL: URL) throws -> [ZoomKeyframe] {
        let data = try Data(contentsOf: bundleURL.appendingPathComponent("keyframes.json"))
        return try JSONDecoder().decode([ZoomKeyframe].self, from: data)
    }

    static func loadEditSettings(from bundleURL: URL) throws -> ProjectEditSettings {
        let url = bundleURL.appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ProjectEditSettings()
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ProjectEditSettings.self, from: data)
    }

    static func loadProject(from bundleURL: URL) throws -> RecorderProject {
        let metadata = try loadMetadata(from: bundleURL)
        let events = try loadEvents(from: bundleURL)
        let cursorEvents = try loadCursorEvents(from: bundleURL)
        let keyframes = try loadKeyframes(from: bundleURL)
        let editSettings = try loadEditSettings(from: bundleURL)
        return RecorderProject(
            metadata: metadata,
            clickEvents: events,
            cursorEvents: cursorEvents,
            keyframes: keyframes,
            editSettings: editSettings
        )
    }
}
