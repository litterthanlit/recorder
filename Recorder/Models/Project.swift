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
    /// Where the take was paused, in seconds on the recording's timeline (paused time is
    /// already left out of the movie).
    let pausePoints: [TimeInterval]
    /// What each audio track in video.mov holds, in track order. Empty for takes from
    /// before this was recorded; see `resolvedAudioTrackRoles(trackCount:)`.
    let audioTrackRoles: [AudioTrackRole]
    /// A name the user gave the project in the library.
    var name: String?

    /// Roles for `trackCount` audio tracks. Older takes recorded the mic first, then
    /// system audio.
    func resolvedAudioTrackRoles(trackCount: Int) -> [AudioTrackRole] {
        if audioTrackRoles.count == trackCount {
            return audioTrackRoles
        }
        return Array([AudioTrackRole.microphone, .systemAudio].prefix(trackCount))
            + Array(repeating: .systemAudio, count: max(0, trackCount - 2))
    }

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
        appName: String? = nil,
        pausePoints: [TimeInterval] = [],
        audioTrackRoles: [AudioTrackRole] = []
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
        self.pausePoints = pausePoints
        self.audioTrackRoles = audioTrackRoles
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
        pausePoints = try container.decodeIfPresent([TimeInterval].self, forKey: .pausePoints) ?? []
        audioTrackRoles = (try? container.decodeIfPresent([AudioTrackRole].self, forKey: .audioTrackRoles)) ?? []
        name = try container.decodeIfPresent(String.self, forKey: .name)
    }
}

struct RecorderProject: Codable, Equatable {
    var metadata: ProjectMetadata
    var clickEvents: [ClickEvent]
    var cursorEvents: [CursorEvent]
    var keyframes: [ZoomKeyframe]
    var editSettings: ProjectEditSettings
    /// Key presses and cursor shapes (inputs.json; empty for older takes).
    var inputs: InputLog

    static let bundleExtension = "recorder"

    var bundleURL: URL {
        ProjectStore.bundleURL(for: metadata.id)
    }

    var videoURL: URL {
        bundleURL.appendingPathComponent("video.mov")
    }

    var eventsURL: URL {
        bundleURL.appendingPathComponent(ProjectStore.File.events)
    }

    var cursorURL: URL {
        bundleURL.appendingPathComponent(ProjectStore.File.cursor)
    }

    var keyframesURL: URL {
        bundleURL.appendingPathComponent(ProjectStore.File.keyframes)
    }

    var metaURL: URL {
        bundleURL.appendingPathComponent(ProjectStore.File.meta)
    }

    var settingsURL: URL {
        bundleURL.appendingPathComponent(ProjectStore.File.settings)
    }

    /// Where builds before export destinations wrote the export (read, never written).
    var legacyExportURL: URL {
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

    /// The latest export's file, if it's still there (reads exports.json).
    var latestExportURL: URL? {
        ProjectStore.latestExport(in: bundleURL)
    }

    /// The picture behind the recording when the background is an image in the bundle.
    var backgroundImageURL: URL? {
        let background = editSettings.exportStyle.background
        guard background.kind == .image, let name = background.imageFileName,
              ProjectStore.isBackgroundImageName(name)
        else { return nil }
        return bundleURL.appendingPathComponent(name)
    }

    init(
        metadata: ProjectMetadata,
        clickEvents: [ClickEvent],
        cursorEvents: [CursorEvent] = [],
        keyframes: [ZoomKeyframe],
        editSettings: ProjectEditSettings = ProjectEditSettings(),
        inputs: InputLog = InputLog()
    ) {
        self.metadata = metadata
        self.clickEvents = clickEvents
        self.cursorEvents = cursorEvents
        self.keyframes = keyframes
        self.editSettings = editSettings
        self.inputs = inputs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try container.decode(ProjectMetadata.self, forKey: .metadata)
        clickEvents = try container.decode([ClickEvent].self, forKey: .clickEvents)
        cursorEvents = try container.decodeIfPresent([CursorEvent].self, forKey: .cursorEvents) ?? []
        keyframes = try container.decode([ZoomKeyframe].self, forKey: .keyframes)
        editSettings = try container.decodeIfPresent(ProjectEditSettings.self, forKey: .editSettings) ?? ProjectEditSettings()
        inputs = try container.decodeIfPresent(InputLog.self, forKey: .inputs) ?? InputLog()
    }
}

/// Version of the files in a project bundle. Bumped when a change means an older build
/// would lose information by rewriting them; a bundle from a newer version is refused.
enum ProjectFormat {
    /// 2: cuts, splits and speed (`ProjectEditSettings.timeline`).
    /// 3: cropping to part of the screen (`ProjectEditSettings.sourceCrop`) and motion:
    /// text animation, cut transitions, speed ramps and 3D camera moves.
    static let current = 3
}

enum ProjectStoreError: LocalizedError, Equatable {
    case newerFormat(Int)

    var errorDescription: String? {
        switch self {
        case .newerFormat:
            return "This project was saved by a newer version of \(Brand.name). Update the app to open it."
        }
    }
}

/// Encodes `value` with a `formatVersion` key added alongside its own keys.
private struct Versioned<Value: Encodable>: Encodable {
    let value: Value

    private enum CodingKeys: String, CodingKey {
        case formatVersion
    }

    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ProjectFormat.current, forKey: .formatVersion)
    }
}

/// Reads only the `formatVersion` key; files written before it existed are version 1.
private struct FormatProbe: Decodable {
    let formatVersion: Int?

    static func check(_ data: Data) throws {
        let version = (try? JSONDecoder().decode(FormatProbe.self, from: data))?.formatVersion ?? 1
        if version > ProjectFormat.current {
            throw ProjectStoreError.newerFormat(version)
        }
    }
}

enum ProjectStore {
    static var projectsDirectory: URL {
        moviesDirectory.appendingPathComponent(Brand.libraryFolderName, isDirectory: true)
    }

    /// The library folder used before the app was renamed (see `LibraryMigration`).
    /// Where exports go unless the user picks another folder.
    static var exportsDirectory: URL {
        projectsDirectory.appendingPathComponent("Exports", isDirectory: true)
    }

    static var legacyProjectsDirectory: URL {
        moviesDirectory.appendingPathComponent(Brand.legacyLibraryFolderName, isDirectory: true)
    }

    private static var moviesDirectory: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies", isDirectory: true)
    }

    /// Where the project with this ID lives in `root` (the library by default).
    static func bundleURL(for id: UUID, in root: URL = projectsDirectory) -> URL {
        root.appendingPathComponent("\(id.uuidString).\(RecorderProject.bundleExtension)", isDirectory: true)
    }

    static func ensureProjectsDirectory() throws {
        try FileManager.default.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
    }

    /// Writes every file of a new project. Writes are atomic, so a crash mid-save
    /// leaves the previous version of a file rather than a truncated one.
    static func save(_ project: RecorderProject) throws {
        try ensureProjectsDirectory()
        try save(project, to: project.bundleURL)
    }

    /// Writes every file of `project` into `bundleURL`, creating it if needed.
    static func save(_ project: RecorderProject, to bundleURL: URL) throws {
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let encoder = makeEncoder()
        try encoder.encode(Versioned(value: project.metadata))
            .write(to: bundleURL.appendingPathComponent(File.meta), options: .atomic)
        try encoder.encode(project.clickEvents).write(to: bundleURL.appendingPathComponent(File.events), options: .atomic)
        try encoder.encode(project.cursorEvents).write(to: bundleURL.appendingPathComponent(File.cursor), options: .atomic)
        try encoder.encode(project.inputs).write(to: bundleURL.appendingPathComponent(File.inputs), options: .atomic)
        try saveEdits(project, to: bundleURL, encoder: encoder)
    }

    /// Writes only what the editor changes (zoom keyframes and edit settings). Metadata,
    /// clicks, and the cursor path are fixed after recording, and the cursor path is by
    /// far the largest file.
    static func saveEdits(_ project: RecorderProject) throws {
        try saveEdits(project, to: project.bundleURL, encoder: makeEncoder())
    }

    static func saveEdits(_ project: RecorderProject, to bundleURL: URL) throws {
        try saveEdits(project, to: bundleURL, encoder: makeEncoder())
    }

    private static func saveEdits(_ project: RecorderProject, to bundleURL: URL, encoder: JSONEncoder) throws {
        try encoder.encode(project.keyframes).write(to: bundleURL.appendingPathComponent(File.keyframes), options: .atomic)
        try encoder.encode(Versioned(value: project.editSettings))
            .write(to: bundleURL.appendingPathComponent(File.settings), options: .atomic)
    }

    /// File names inside a project bundle.
    enum File {
        static let video = "video.mov"
        static let meta = "meta.json"
        static let events = "events.json"
        static let cursor = "cursor.json"
        static let keyframes = "keyframes.json"
        static let settings = "settings.json"
        static let inputs = "inputs.json"
        static let export = "export.mp4"
        static let exports = "exports.json"
    }

    /// Remembers where a project was last exported to.
    static func saveExportRecord(_ record: ExportRecord, in bundleURL: URL) throws {
        try makeEncoder().encode(record)
            .write(to: bundleURL.appendingPathComponent(File.exports), options: .atomic)
    }

    /// The project's latest export if its file is still there: the recorded one, or the
    /// export.mp4 older builds wrote into the bundle.
    static func latestExport(in bundleURL: URL) -> URL? {
        let fileManager = FileManager.default
        if let data = try? Data(contentsOf: bundleURL.appendingPathComponent(File.exports)) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let record = try? decoder.decode(ExportRecord.self, from: data),
               fileManager.fileExists(atPath: record.path) {
                return record.url
            }
        }
        let legacy = bundleURL.appendingPathComponent(File.export)
        return fileManager.fileExists(atPath: legacy.path) ? legacy : nil
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func loadMetadata(from bundleURL: URL) throws -> ProjectMetadata {
        let data = try Data(contentsOf: bundleURL.appendingPathComponent(File.meta))
        try FormatProbe.check(data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ProjectMetadata.self, from: data)
    }

    static func loadEvents(from bundleURL: URL) throws -> [ClickEvent] {
        let data = try Data(contentsOf: bundleURL.appendingPathComponent(File.events))
        return try JSONDecoder().decode([ClickEvent].self, from: data)
    }

    static func loadCursorEvents(from bundleURL: URL) throws -> [CursorEvent] {
        let url = bundleURL.appendingPathComponent(File.cursor)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([CursorEvent].self, from: data)
    }

    /// Key presses and cursor shapes; empty for takes recorded before they were tracked,
    /// and for a damaged file (they only drive optional overlays).
    static func loadInputs(from bundleURL: URL) -> InputLog {
        let url = bundleURL.appendingPathComponent(File.inputs)
        guard let data = try? Data(contentsOf: url) else { return InputLog() }
        return (try? JSONDecoder().decode(InputLog.self, from: data)) ?? InputLog()
    }

    /// Copies a picture into the bundle for an image background and returns its file
    /// name there (for `BackgroundStyle.imageFileName`). The bundle keeps its own copy so
    /// the project still renders if the original moves.
    static func importBackgroundImage(from sourceURL: URL, into bundleURL: URL) throws -> String {
        let pathExtension = sourceURL.pathExtension.lowercased()
        let allowed = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "webp", "gif", "bmp"]
        let ext = allowed.contains(pathExtension) ? pathExtension : "png"
        let name = "\(backgroundImagePrefix)\(UUID().uuidString.prefix(8).lowercased()).\(ext)"
        try FileManager.default.copyItem(at: sourceURL, to: bundleURL.appendingPathComponent(name))
        return name
    }

    /// Removes background pictures in the bundle other than `keeping`.
    static func removeUnusedBackgroundImages(in bundleURL: URL, keeping name: String?) {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(atPath: bundleURL.path) else { return }
        for file in contents where isBackgroundImageName(file) && file != name {
            try? fileManager.removeItem(at: bundleURL.appendingPathComponent(file))
        }
    }

    private static let backgroundImagePrefix = "background-"

    /// A file name this app gave an imported background (never a path, so a
    /// hand-edited settings.json can't point outside the bundle).
    static func isBackgroundImageName(_ name: String) -> Bool {
        name.hasPrefix(backgroundImagePrefix) && !name.contains("/") && !name.contains("..")
    }

    /// Names a project (an empty name clears it). Only meta.json is rewritten.
    static func rename(bundleURL: URL, to name: String) throws {
        var metadata = try loadMetadata(from: bundleURL)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        metadata.name = trimmed.isEmpty ? nil : trimmed
        try makeEncoder().encode(Versioned(value: metadata))
            .write(to: bundleURL.appendingPathComponent(File.meta), options: .atomic)
    }

    static func loadKeyframes(from bundleURL: URL) throws -> [ZoomKeyframe] {
        let data = try Data(contentsOf: bundleURL.appendingPathComponent(File.keyframes))
        return try JSONDecoder().decode([ZoomKeyframe].self, from: data)
    }

    static func loadEditSettings(from bundleURL: URL) throws -> ProjectEditSettings {
        let url = bundleURL.appendingPathComponent(File.settings)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ProjectEditSettings()
        }
        let data = try Data(contentsOf: url)
        try FormatProbe.check(data)
        return try JSONDecoder().decode(ProjectEditSettings.self, from: data)
    }

    /// `project` with its zooms and edit settings read again from disk: an AI agent may
    /// have changed them since this copy was made (after a take, say). The copy's own are
    /// kept where the files can't be read.
    static func reloadingEdits(of project: RecorderProject) -> RecorderProject {
        var current = project
        if let keyframes = try? loadKeyframes(from: project.bundleURL) {
            current.keyframes = keyframes
        }
        if let settings = try? loadEditSettings(from: project.bundleURL) {
            current.editSettings = settings
        }
        return current
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
            editSettings: editSettings,
            inputs: loadInputs(from: bundleURL)
        )
    }
}

/// What the Recent Projects list shows. Built from a project's `meta.json` only, so
/// listing never loads click or cursor data.
struct ProjectSummary: Identifiable, Equatable {
    let id: UUID
    let bundleURL: URL
    let createdAt: Date
    let duration: TimeInterval
    let title: String
    /// The user's name for it, if any.
    let name: String?
    /// The latest export's file, if it's still there.
    let latestExport: URL?

    var hasExport: Bool {
        latestExport != nil
    }

    /// What the library shows: the user's name, or a description of what was recorded.
    var displayName: String {
        name ?? title
    }

    /// Case- and accent-insensitive search on the name and the description.
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return [displayName, title].contains {
            $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    var videoURL: URL {
        bundleURL.appendingPathComponent("video.mov")
    }

    init(metadata: ProjectMetadata, bundleURL: URL, latestExport: URL? = nil) {
        id = metadata.id
        self.bundleURL = bundleURL
        createdAt = metadata.createdAt
        duration = metadata.duration
        title = Self.title(for: metadata)
        name = metadata.name
        self.latestExport = latestExport
    }

    /// "Google Chrome — Hypher", "Google Chrome", or "Full display".
    static func title(for metadata: ProjectMetadata) -> String {
        switch metadata.captureTarget {
        case .display:
            return "Full display"
        case .area:
            let app = metadata.appName?.trimmingCharacters(in: .whitespaces) ?? ""
            return app.isEmpty ? "Screen area" : "\(app) — area"
        case .window:
            let app = metadata.appName?.trimmingCharacters(in: .whitespaces) ?? ""
            let window = metadata.windowTitle?.trimmingCharacters(in: .whitespaces) ?? ""
            switch (app.isEmpty, window.isEmpty) {
            case (false, false):
                return "\(app) — \(window)"
            case (false, true):
                return app
            case (true, false):
                return window
            case (true, true):
                return "Window recording"
            }
        }
    }
}

/// Orders for the library.
enum ProjectSort: String, CaseIterable, Identifiable {
    case newest
    case oldest
    case longest
    case name

    var id: String { rawValue }

    var label: String {
        switch self {
        case .newest: return "Newest First"
        case .oldest: return "Oldest First"
        case .longest: return "Longest First"
        case .name: return "Name"
        }
    }

    func sorted(_ projects: [ProjectSummary]) -> [ProjectSummary] {
        switch self {
        case .newest:
            return projects.sorted { $0.createdAt > $1.createdAt }
        case .oldest:
            return projects.sorted { $0.createdAt < $1.createdAt }
        case .longest:
            return projects.sorted { $0.duration > $1.duration }
        case .name:
            return projects.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
        }
    }
}

extension ProjectStore {
    /// Projects in the library, newest first. Bundles that can't be read are skipped.
    static func listProjects(in root: URL = projectsDirectory, limit: Int? = nil) -> [ProjectSummary] {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let summaries = urls
            .filter { $0.pathExtension == RecorderProject.bundleExtension }
            .compactMap { url -> ProjectSummary? in
                guard let metadata = try? loadMetadata(from: url) else { return nil }
                return ProjectSummary(metadata: metadata, bundleURL: url, latestExport: latestExport(in: url))
            }
            .sorted { $0.createdAt > $1.createdAt }

        if let limit {
            return Array(summaries.prefix(limit))
        }
        return summaries
    }
}

/// Saves editor changes off the main thread, coalescing bursts (dragging a trim handle,
/// typing a watermark) into one write shortly after they stop.
final class ProjectAutosaver: @unchecked Sendable {
    // All mutable state is confined to `queue`.
    private let queue = DispatchQueue(label: "com.recorder.project-autosave", qos: .utility)
    private let delay: TimeInterval
    private var pendingProject: RecorderProject?
    private var generation = 0

    init(delay: TimeInterval = 0.3) {
        self.delay = delay
    }

    /// Saves `project` after `delay`, unless a newer version is scheduled first.
    func schedule(_ project: RecorderProject) {
        queue.async { [self] in
            generation += 1
            let scheduledGeneration = generation
            pendingProject = project
            queue.asyncAfter(deadline: .now() + delay) { [self] in
                guard scheduledGeneration == generation else { return }
                writePending()
            }
        }
    }

    /// Writes any pending change now and waits for it (before export or quitting).
    func flush() {
        queue.sync {
            writePending()
        }
    }

    private func writePending() {
        guard let project = pendingProject else { return }
        pendingProject = nil
        do {
            try ProjectStore.saveEdits(project)
        } catch {
            Log.editor.error("Autosave failed for \(project.metadata.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
