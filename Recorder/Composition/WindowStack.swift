import CoreGraphics
import Foundation

/// Reading the window server's on-screen windows (front to back): which window an app is
/// showing, and what other apps put over it.
enum WindowStack {
    /// Ordinary app windows.
    static let normalLayer = 0
    /// The menu bar. Status items, overlays and the cursor sit above it.
    static let menuBarLayer = 24
    /// Menus, like another app's menu bar extra.
    static let popUpMenuLayer = 101
    /// A smaller window isn't taken for an app's window.
    static let minimumSide: CGFloat = 40
    /// A window with this much of itself inside a bigger one of the same app belongs to
    /// it, like a sheet on its document window.
    static let containedShare: CGFloat = 0.8
    /// Less opaque windows aren't seen.
    static let minimumAlpha = 0.1

    /// `pid`'s window in front: its frontmost ordinary window, or the bigger window of the
    /// app that one sits in (a sheet or a panel inside its document window).
    static func frontWindow(of pid: Int32, frontToBack windows: [WindowSnapshot]) -> WindowSnapshot? {
        let own = windows.filter {
            $0.ownerPID == pid && $0.layer == normalLayer
                && $0.bounds.width > minimumSide && $0.bounds.height > minimumSide
        }
        guard var front = own.first else { return nil }
        // Each step moves to a bigger window, so this ends.
        while let holder = own.first(where: { area($0.bounds) > area(front.bounds) && share(of: front.bounds, inside: $0.bounds) >= containedShare }) {
            front = holder
        }
        return front
    }

    /// Other apps' windows in front of `window` that overlap it, front to back: what
    /// covers part of it in the picture. Leaves out the windows of `ignoredPIDs` (Trace,
    /// apps kept out of the recording), see-through and unshared windows, the menu bar
    /// and everything above it except menus, and floating windows over the whole of
    /// `window` (full-screen overlays, which usually draw nothing).
    static func covers(
        of window: WindowSnapshot,
        frontToBack windows: [WindowSnapshot],
        ignoredPIDs: Set<Int32> = []
    ) -> [WindowSnapshot] {
        guard let index = windows.firstIndex(where: { $0.windowID == window.windowID }) else { return [] }
        return windows[..<index].filter { other in
            let seen = other.alpha >= minimumAlpha && other.isShared
            let layered = (other.layer >= normalLayer && other.layer < menuBarLayer) || other.layer == popUpMenuLayer
            let overlay = other.layer != normalLayer && other.bounds.contains(window.bounds)
            let overlap = other.bounds.intersection(window.bounds)
            return other.ownerPID != window.ownerPID
                && !ignoredPIDs.contains(other.ownerPID)
                && seen
                && layered
                && !overlay
                && !overlap.isNull && overlap.width > 1 && overlap.height > 1
        }
    }

    /// How much of `rect` lies inside `container` (0–1).
    static func share(of rect: CGRect, inside container: CGRect) -> CGFloat {
        let whole = area(rect)
        guard whole > 0 else { return 0 }
        let inside = rect.intersection(container)
        return inside.isNull ? 0 : area(inside) / whole
    }

    static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : max(rect.width, 0) * max(rect.height, 0)
    }
}
