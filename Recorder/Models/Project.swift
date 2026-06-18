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

    var captureOrigin: CGPoint {
        CGPoint(x: captureOriginX, y: captureOriginY)
    }
}

struct RecorderProject: Codable, Equatable {
    var metadata: ProjectMetadata
    var clickEvents: [ClickEvent]
    var keyframes: [ZoomKeyframe]

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

    var keyframesURL: URL {
        bundleURL.appendingPathComponent("keyframes.json")
    }

    var metaURL: URL {
        bundleURL.appendingPathComponent("meta.json")
    }

    var exportURL: URL {
        bundleURL.appendingPathComponent("export.mp4")
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
        try encoder.encode(project.keyframes).write(to: project.keyframesURL)
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

    static func loadKeyframes(from bundleURL: URL) throws -> [ZoomKeyframe] {
        let data = try Data(contentsOf: bundleURL.appendingPathComponent("keyframes.json"))
        return try JSONDecoder().decode([ZoomKeyframe].self, from: data)
    }

    static func loadProject(from bundleURL: URL) throws -> RecorderProject {
        let metadata = try loadMetadata(from: bundleURL)
        let events = try loadEvents(from: bundleURL)
        let keyframes = try loadKeyframes(from: bundleURL)
        return RecorderProject(metadata: metadata, clickEvents: events, keyframes: keyframes)
    }
}
