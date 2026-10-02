import AppKit
import CoreGraphics
import Foundation

/// Notes which app is in front during a take, four times a second and whenever another
/// app comes forward, with where its front window sits in the recording. Trace's own
/// windows don't count. Runs on the main run loop.
final class AppFocusSampler {
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private let lock = NSLock()
    private var events: [AppFocusEvent] = []
    private var clock: RecordingClock?
    /// Where a window (global points, top-left origin) is in the recording.
    private var locate: ((CGRect) -> CGRect?)?
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    func start(clock: RecordingClock, locate: @escaping (CGRect) -> CGRect?) {
        stop()
        self.clock = clock
        self.locate = locate
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
        let window = Self.frontWindow(of: app.processIdentifier)
        let event = AppFocusEvent(
            timestamp: time,
            bundleID: app.bundleIdentifier,
            appName: app.localizedName ?? app.bundleIdentifier ?? "App",
            windowRect: window.flatMap { locate?($0) }
        )
        lock.lock()
        AppFocusTimeline.append(event, to: &events)
        lock.unlock()
    }

    /// The app's front ordinary window, in global points with a top-left origin.
    private static func frontWindow(of pid: pid_t) -> CGRect? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for info in list {
            let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard owner == pid, layer == 0,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                  bounds.width > 40, bounds.height > 40
            else { continue }
            return bounds
        }
        return nil
    }
}
