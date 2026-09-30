import AVFoundation
import Foundation

/// Exports a project as saved, with or without an open editor (the editor's Export
/// button, and Quick Access's Export and Copy).
enum ExportService {
    static func configuration(for project: RecorderProject) async throws -> ExportConfiguration {
        let settings = project.editSettings
        let sourceSize = CGSize(width: project.metadata.width, height: project.metadata.height)
        let outputSize = settings.canvas.pixelSize(source: sourceSize)
        let audioTrackCount = try await AVURLAsset(url: project.videoURL).loadTracks(withMediaType: .audio).count
        return ExportConfiguration(
            keyframes: project.keyframes,
            outputSize: outputSize,
            bitrate: ExportBitrate.target(for: outputSize, fps: project.metadata.fps),
            timeline: settings.resolvedTimeline(sourceDuration: project.metadata.duration),
            render: CompositionRenderSettings(project: project, editSettings: settings),
            frameRate: project.metadata.fps,
            cameraURL: project.hasCameraTrack ? project.cameraURL : nil,
            audioTrackRoles: project.metadata.resolvedAudioTrackRoles(trackCount: audioTrackCount),
            audio: settings.audio
        )
    }

    /// Writes the export to the project's `export.mp4` and returns its URL.
    /// - Parameter progress: 0…1, called on the main actor.
    @discardableResult
    static func export(
        _ project: RecorderProject,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        // The recorded cursor is drawn with the system's own cursor images.
        await SystemCursorImages.shared.load()
        let configuration = try await configuration(for: project)
        try await VideoExporter().export(
            sourceURL: project.videoURL,
            outputURL: project.exportURL,
            configuration: configuration
        ) { value in
            Task { @MainActor in progress(value) }
        }
        return project.exportURL
    }
}
