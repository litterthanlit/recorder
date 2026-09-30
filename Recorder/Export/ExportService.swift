import AVFoundation
import Foundation

/// Exports a project as saved, with or without an open editor (the editor's export
/// sheet, and Quick Access's Export and Copy).
enum ExportService {
    static func configuration(for project: RecorderProject, options: ExportOptions) async throws -> ExportConfiguration {
        let settings = project.editSettings
        let sourceSize = CGSize(width: project.metadata.width, height: project.metadata.height)
        let canvasSize = settings.canvas.pixelSize(source: sourceSize)
        let audioTrackCount = try await AVURLAsset(url: project.videoURL).loadTracks(withMediaType: .audio).count
        return ExportConfiguration(
            keyframes: project.keyframes,
            outputSize: options.outputSize(canvas: canvasSize),
            timeline: settings.resolvedTimeline(sourceDuration: project.metadata.duration),
            render: CompositionRenderSettings(project: project, editSettings: settings),
            frameRate: options.outputFrameRate(source: project.metadata.fps),
            options: options,
            cameraURL: project.hasCameraTrack ? project.cameraURL : nil,
            audioTrackRoles: project.metadata.resolvedAudioTrackRoles(trackCount: audioTrackCount),
            audio: settings.audio
        )
    }

    /// Exports to `destination`, replacing a file already there, and remembers it as the
    /// project's latest export. The file is written next to it first and moved into place
    /// when complete, so a cancelled or failed export never leaves a broken file behind.
    /// - Parameter progress: 0…1, called on the main actor.
    @discardableResult
    static func export(
        _ project: RecorderProject,
        options: ExportOptions,
        to destination: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        // The recorded cursor is drawn with the system's own cursor images.
        await SystemCursorImages.shared.load()
        let configuration = try await configuration(for: project, options: options)

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let workDirectory = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: destination,
            create: true
        )
        defer { try? fileManager.removeItem(at: workDirectory) }
        let partialURL = workDirectory.appendingPathComponent(destination.lastPathComponent)

        try await VideoExporter().export(
            sourceURL: project.videoURL,
            outputURL: partialURL,
            configuration: configuration
        ) { value in
            Task { @MainActor in progress(value) }
        }
        try Task.checkCancellation()

        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: partialURL)
        } else {
            try fileManager.moveItem(at: partialURL, to: destination)
        }

        let record = ExportRecord(path: destination.path, format: options.format, date: Date())
        do {
            try ProjectStore.saveExportRecord(record, in: project.bundleURL)
        } catch {
            Log.export.error("Couldn't remember the export: \(error.localizedDescription, privacy: .public)")
        }
        return destination
    }

    /// Where an export goes without asking: the export folder, named from the template,
    /// never replacing an existing file.
    static func automaticDestination(for project: RecorderProject, preferences: ExportPreferences) -> URL {
        let name = project.metadata.name ?? ProjectSummary.title(for: project.metadata)
        let fileName = ExportNaming.fileName(
            template: preferences.fileNameTemplate,
            name: name,
            date: project.metadata.createdAt,
            fileExtension: preferences.options.format.fileExtension
        )
        return ExportNaming.uniqueURL(in: preferences.folderURL, fileName: fileName) {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    /// Exports with the saved preferences to the export folder (Quick Access). A GIF
    /// preference falls back to MP4 when the edit is too long for a GIF.
    @discardableResult
    static func export(
        _ project: RecorderProject,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        var preferences = ExportPreferences.load()
        let duration = project.editSettings.resolvedTimeline(sourceDuration: project.metadata.duration).outputDuration
        if !ExportOptions.allows(preferences.options.format, duration: duration) {
            preferences.options.format = .mp4
        }
        let destination = automaticDestination(for: project, preferences: preferences)
        return try await export(project, options: preferences.options, to: destination, progress: progress)
    }
}
