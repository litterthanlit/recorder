import AppKit
import AVFoundation
import Foundation

/// The recordings on disk: the menu bar panel's Recent list and the Library window.
/// Reads project bundles, makes thumbnails, renames projects and moves them to the Trash.
@MainActor
final class ProjectLibrary: ObservableObject {
    /// Kept short so the menu bar panel stays within a laptop screen's height.
    static let recentLimit = 4

    @Published private(set) var recentProjects: [ProjectSummary] = []
    /// Every project, newest first.
    @Published private(set) var allProjects: [ProjectSummary] = []

    private let thumbnails = NSCache<NSUUID, NSImage>()
    private var refreshGeneration = 0

    init() {
        thumbnails.countLimit = 200
    }

    /// Re-reads the project folder in the background.
    func refresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        Task {
            let projects = await Task.detached(priority: .userInitiated) {
                ProjectStore.listProjects()
            }.value
            // A newer refresh may have started meanwhile.
            guard generation == refreshGeneration else { return }
            allProjects = projects
            recentProjects = Array(projects.prefix(Self.recentLimit))
        }
    }

    /// Gives a project a name in the library.
    func rename(_ project: ProjectSummary, to name: String) {
        do {
            try ProjectStore.rename(bundleURL: project.bundleURL, to: name)
        } catch {
            Log.library.error("Rename failed: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
        refresh()
    }

    /// A small still from about a second into the recording, cached per project.
    func thumbnail(for project: ProjectSummary) async -> NSImage? {
        if let cached = thumbnails.object(forKey: project.id as NSUUID) {
            return cached
        }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: project.videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 300)
        let time = CMTime(seconds: min(1, max(0, project.duration / 2)), preferredTimescale: 600)
        let result: (image: CGImage, actualTime: CMTime)
        do {
            result = try await generator.image(at: time)
        } catch {
            Log.library.error("Thumbnail failed for \(project.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let image = NSImage(cgImage: result.image, size: .zero)
        thumbnails.setObject(image, forKey: project.id as NSUUID)
        return image
    }

    /// Moves the whole project bundle (recording, camera track, export) to the Trash,
    /// where it can still be recovered.
    func moveToTrash(_ project: ProjectSummary) throws {
        try FileManager.default.trashItem(at: project.bundleURL, resultingItemURL: nil)
        thumbnails.removeObject(forKey: project.id as NSUUID)
        recentProjects.removeAll { $0.id == project.id }
        allProjects.removeAll { $0.id == project.id }
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
