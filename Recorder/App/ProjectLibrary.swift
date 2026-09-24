import AppKit
import AVFoundation
import Foundation

/// The recordings shown in the menu bar panel's Recent list: reads project bundles from
/// disk, makes their thumbnails, and moves projects to the Trash.
@MainActor
final class ProjectLibrary: ObservableObject {
    /// Kept short so the menu bar panel stays within a laptop screen's height.
    static let recentLimit = 4

    @Published private(set) var recentProjects: [ProjectSummary] = []

    private var thumbnails: [UUID: NSImage] = [:]
    private var refreshGeneration = 0

    /// Re-reads the project folder in the background.
    func refresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        let limit = Self.recentLimit
        Task {
            let projects = await Task.detached(priority: .userInitiated) {
                ProjectStore.listProjects(limit: limit)
            }.value
            // A newer refresh may have started meanwhile.
            guard generation == refreshGeneration else { return }
            recentProjects = projects
        }
    }

    /// A small still from about a second into the recording, cached per project.
    func thumbnail(for project: ProjectSummary) async -> NSImage? {
        if let cached = thumbnails[project.id] {
            return cached
        }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: project.videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 150)
        let time = CMTime(seconds: min(1, max(0, project.duration / 2)), preferredTimescale: 600)
        guard let result = try? await generator.image(at: time) else { return nil }

        let image = NSImage(cgImage: result.image, size: .zero)
        thumbnails[project.id] = image
        return image
    }

    /// Moves the whole project bundle (recording, camera track, export) to the Trash,
    /// where it can still be recovered.
    func moveToTrash(_ project: ProjectSummary) throws {
        try FileManager.default.trashItem(at: project.bundleURL, resultingItemURL: nil)
        thumbnails[project.id] = nil
        recentProjects.removeAll { $0.id == project.id }
        refresh()
    }

    /// Shows the export in Finder if there is one, otherwise the project bundle.
    func reveal(_ project: ProjectSummary) {
        let target = project.hasExport ? project.exportURL : project.bundleURL
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func revealProjectsFolder() {
        try? ProjectStore.ensureProjectsDirectory()
        NSWorkspace.shared.open(ProjectStore.projectsDirectory)
    }
}
