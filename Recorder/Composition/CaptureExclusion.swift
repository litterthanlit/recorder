import Foundation

/// Which apps to leave out of a display or area recording, for a clean screen without
/// changing any system setting: the app's own windows always, Notification Center's
/// banners (and desktop widgets) and Finder's desktop icons on request.
enum CaptureExclusion {
    static let notificationCenterBundleID = "com.apple.notificationcenterui"
    static let finderBundleID = "com.apple.finder"

    struct Window: Equatable {
        let windowID: UInt32
        let bundleID: String?
        /// Window level; 0 is ordinary windows. Finder draws desktop icons far below that.
        let layer: Int
    }

    struct Plan: Equatable {
        /// Apps whose windows are left out.
        var excludedBundleIDs: Set<String>
        /// Windows of excluded apps that are recorded anyway.
        var exceptedWindowIDs: Set<UInt32>
    }

    static func plan(
        ownBundleID: String?,
        windows: [Window],
        hideDesktopIcons: Bool,
        hideNotifications: Bool
    ) -> Plan {
        var excluded: Set<String> = []
        if let ownBundleID {
            excluded.insert(ownBundleID)
        }
        if hideNotifications {
            excluded.insert(notificationCenterBundleID)
        }
        var excepted: Set<UInt32> = []
        if hideDesktopIcons {
            // Leaving out Finder removes the desktop icons; its ordinary windows (Finder
            // browser windows someone is demoing) are kept.
            excluded.insert(finderBundleID)
            excepted = Set(windows.filter { $0.bundleID == finderBundleID && $0.layer == 0 }.map(\.windowID))
        }
        return Plan(excludedBundleIDs: excluded, exceptedWindowIDs: excepted)
    }
}
