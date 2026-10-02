import AppKit
import CoreGraphics
import Foundation

/// Notes which app is in front during a take, four times a second and whenever another
/// app comes forward, with where its front window sits in the recording and which other
/// apps' windows lie over it. Trace's own windows don't count. Runs on the main run loop.
final class AppFocusSampler {
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private let lock = NSLock()
    private var events: [AppFocusEvent] = []
    private var clock: RecordingClock?
    /// Where a window (global points, top-left origin) is in the recording.
    private var locate: ((CGRect) -> CGRect?)?
    /// Whether other apps' windows can show in the recording (not in a window recording,
    /// which shows only its window).
    private var recordsCovers = true
    /// Apps left out of the recording (notification banners on request): their windows
    /// don't cover anything in it.
    private var ignoredBundleIDs: Set<String> = []
    /// Names and bundle IDs by process, looked up once per take.
    private var apps: [pid_t: (name: String, bundleID: String?)] = [:]
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    func start(
        clock: RecordingClock,
        recordsCovers: Bool,
        ignoredBundleIDs: Set<String>,
        locate: @escaping (CGRect) -> CGRect?
    ) {
        stop()
        self.clock = clock
        self.locate = locate
        self.recordsCovers = recordsCovers
        self.ignoredBundleIDs = ignoredBundleIDs
        apps = [:]
        lock.lock()
        events = []
        lock.unlock()

        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.sample()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.sample()
        }
        sample()
    }

    @discardableResult
    func stop() -> [AppFocusEvent] {
        timer?.invalidate()
        timer = nil
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    private func sample() {
        guard let clock,
              let time = clock.recordingSeconds(forHostSeconds: CACurrentMediaTime()),
              let app = NSWorkspace.shared.frontmostApplication,
              // Trace's panel or selector in front: whatever is behind it still counts.
              app.processIdentifier != ownPID
        else { return }
        let windows = Self.onScreenWindows()
        let front = WindowStack.frontWindow(of: app.processIdentifier, frontToBack: windows)
        var covers: [WindowCover] = []
        if recordsCovers, let front {
            covers = WindowStack.covers(of: front, frontToBack: windows, ignoredPIDs: [ownPID]).compactMap { window in
                cover(window, over: app)
            }
        }
        let event = AppFocusEvent(
            timestamp: time,
            bundleID: app.bundleIdentifier,
            appName: app.localizedName ?? app.bundleIdentifier ?? "App",
            windowRect: front.flatMap { locate?($0.bounds) },
            covers: covers
        )
        lock.lock()
        AppFocusTimeline.append(event, to: &events)
        lock.unlock()
    }

    /// `window` as a cover over `app`'s window, unless it's out of the recording or part
    /// of `app` after all (a helper process, like a browser's).
    private func cover(_ window: WindowSnapshot, over app: NSRunningApplication) -> WindowCover? {
        let owner = describe(window.ownerPID)
        if let bundleID = owner.bundleID {
            if ignoredBundleIDs.contains(bundleID) {
                return nil
            }
            if let front = app.bundleIdentifier, bundleID.hasPrefix(front + ".") {
                return nil
            }
        }
        guard let rect = locate?(window.bounds) else { return nil }
        return WindowCover(appName: owner.name, bundleID: owner.bundleID, rect: rect)
    }

    private func describe(_ pid: pid_t) -> (name: String, bundleID: String?) {
        if let known = apps[pid] {
            return known
        }
        let running = NSRunningApplication(processIdentifier: pid)
        let found = (name: running?.localizedName ?? running?.bundleIdentifier ?? "App", bundleID: running?.bundleIdentifier)
        apps[pid] = found
        return found
    }

    /// On-screen windows, front to back, in global points with a top-left origin.
    private static func onScreenWindows() -> [WindowSnapshot] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard let number = info[kCGWindowNumber as String] as? NSNumber,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary)
            else { return nil }
            let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            let sharing = (info[kCGWindowSharingState as String] as? NSNumber)?.intValue ?? 1
            return WindowSnapshot(
                windowID: number.uint32Value,
                layer: layer,
                bounds: bounds,
                ownerPID: owner,
                alpha: alpha,
                isShared: sharing != 0
            )
        }
    }
}
