import Foundation

/// Moves projects from the pre-rename library folder (`~/Movies/Recorder`) to the current
/// one. Only project bundles move: "Recorder" is a generic name another app may also use.
/// Nothing is ever overwritten, running it again changes nothing, and the old folder is
/// removed only once it's empty.
enum LibraryMigration {
    struct Report: Equatable {
        /// The whole folder was renamed (it held nothing but projects).
        var renamedFolder = false
        /// Bundles moved one by one.
        var movedBundles: [String] = []
        /// Bundles left behind because the destination already has one with that name,
        /// or the move failed.
        var skippedBundles: [String] = []
        var removedLegacyFolder = false

        var didChangeAnything: Bool {
            renamedFolder || !movedBundles.isEmpty || removedLegacyFolder
        }
    }

    static func migrate(from legacy: URL, to destination: URL, fileManager: FileManager = .default) -> Report {
        var report = Report()
        guard isDirectory(legacy, fileManager: fileManager),
              let contents = try? fileManager.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)
        else {
            return report
        }

        let bundles = contents
            .filter { $0.pathExtension == RecorderProject.bundleExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let others = contents.filter { $0.pathExtension != RecorderProject.bundleExtension }
        guard !bundles.isEmpty else { return report }

        // Nothing but projects (and Finder's .DS_Store) and no new folder yet: rename it.
        if !fileManager.fileExists(atPath: destination.path), others.allSatisfy(isFinderMetadata) {
            do {
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.moveItem(at: legacy, to: destination)
                report.renamedFolder = true
                return report
            } catch {
                // Fall through and move the bundles one at a time.
            }
        }

        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            report.skippedBundles = bundles.map(\.lastPathComponent)
            return report
        }

        for bundle in bundles {
            let target = destination.appendingPathComponent(bundle.lastPathComponent, isDirectory: true)
            if fileManager.fileExists(atPath: target.path) {
                report.skippedBundles.append(bundle.lastPathComponent)
                continue
            }
            do {
                try fileManager.moveItem(at: bundle, to: target)
                report.movedBundles.append(bundle.lastPathComponent)
            } catch {
                report.skippedBundles.append(bundle.lastPathComponent)
            }
        }

        let remaining = (try? fileManager.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)) ?? []
        if remaining.allSatisfy(isFinderMetadata) {
            do {
                try fileManager.removeItem(at: legacy)
                report.removedLegacyFolder = true
            } catch {
                // Harmless: an empty folder stays behind.
            }
        }
        return report
    }

    /// Migrates `~/Movies/Recorder` into the current library folder.
    @discardableResult
    static func migrateDefaultLibrary() -> Report {
        let report = migrate(from: ProjectStore.legacyProjectsDirectory, to: ProjectStore.projectsDirectory)
        if report.didChangeAnything {
            Log.library.notice(
                "Library migration: renamed \(report.renamedFolder), moved \(report.movedBundles.count), skipped \(report.skippedBundles.count)"
            )
        } else if !report.skippedBundles.isEmpty {
            Log.library.warning("Library migration left \(report.skippedBundles.count) projects in the old folder")
        }
        return report
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func isFinderMetadata(_ url: URL) -> Bool {
        url.lastPathComponent == ".DS_Store"
    }
}
