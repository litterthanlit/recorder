import Foundation

/// The product's user-facing identity. The bundle ID, target, module and the `.recorder`
/// project bundle extension keep their original names so macOS permissions and existing
/// projects carry over.
enum Brand {
    static let name = "Trace"
    static let tagline = "Polished product demos, straight from your screen."

    /// `~/Movies/<libraryFolderName>` holds the projects.
    static let libraryFolderName = "Trace"
    /// Where builds before the rename kept their projects.
    static let legacyLibraryFolderName = "Recorder"
}
