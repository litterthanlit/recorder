import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

final class InputTracker {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var startTime: TimeInterval = 0
    private var captureOrigin: CGPoint = .zero
    private var captureSize: CGSize = .zero
    private var scaleFactor: CGFloat = 1
    private let lock = NSLock()
    private var events: [ClickEvent] = []
    private var cursorEvents: [CursorEvent] = []
    private var trackCursor = true
    /// In window mode, the recorded window: its position is followed during the take, and
    /// clicks on other windows covering it are ignored.
    private var trackedWindowID: UInt32?
    private var windowFrameTimer: Timer?
    private var lastCursorSampleTime: TimeInterval = 0
    private let cursorSampleInterval: TimeInterval = 1.0 / 60.0

    var onEvent: ((ClickEvent) -> Void)?

    func configure(
        startTime: TimeInterval,
        captureOrigin: CGPoint,
        captureSize: CGSize,
        scaleFactor: CGFloat,
        trackCursor: Bool = true,
        trackedWindowID: UInt32? = nil
    ) {
        self.startTime = startTime
        self.captureOrigin = captureOrigin
        self.captureSize = captureSize
        self.scaleFactor = scaleFactor
        self.trackCursor = trackCursor
        self.trackedWindowID = trackedWindowID
        events = []
        cursorEvents = []
        lastCursorSampleTime = 0
    }

    func start() throws {
        guard eventTap == nil else { return }

        var mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
        if trackCursor {
            mask |= (1 << CGEventType.mouseMoved.rawValue) | (1 << CGEventType.leftMouseDragged.rawValue) | (1 << CGEventType.rightMouseDragged.rawValue)
        }

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let tracker = Unmanaged<InputTracker>.fromOpaque(userInfo).takeUnretainedValue()
            tracker.handle(event: event, type: type)
            return Unmanaged.passUnretained(event)
        }

        // Listen-only: the system doesn't wait for this callback before delivering
        // events, so a busy main thread here can't make the mouse lag system-wide.
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: CGEventMask(mask),
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            throw InputTrackerError.accessibilityRequired
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        if trackedWindowID != nil {
            // The capture follows the window wherever it goes; follow it here too, or a
            // window moved mid-take maps every later click to the wrong spot. Same run
            // loop as the tap, so no locking.
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.refreshWindowOrigin()
            }
            RunLoop.main.add(timer, forMode: .common)
            windowFrameTimer = timer
        }
    }

    func stop() -> (clicks: [ClickEvent], cursor: [CursorEvent]) {
        windowFrameTimer?.invalidate()
        windowFrameTimer = nil
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil

        lock.lock()
        defer { lock.unlock() }
        return (events, cursorEvents)
    }

    private func handle(event: CGEvent, type: CGEventType) {
        // macOS switches a tap off if it responds too slowly or on some user input, and
        // tells us with these event types. Turn it back on, or click tracking (and with it
        // auto zoom) silently stops for the rest of the take.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }

        let timestamp = CACurrentMediaTime() - startTime
        let global = event.location
        let isClick = type == .leftMouseDown || type == .rightMouseDown
        if isClick, let trackedWindowID {
            refreshWindowOrigin()
            // A click on a window covering the recorded one isn't in the recording.
            guard WindowHitTest.isFrontmost(trackedWindowID, at: global, frontToBack: Self.onScreenWindows()) else {
                return
            }
        }
        let local = convertToCaptureCoordinates(global: global)

        guard captureSize.width > 0, captureSize.height > 0 else { return }
        guard local.x >= 0, local.y >= 0, local.x <= captureSize.width, local.y <= captureSize.height else {
            return
        }

        switch type {
        case .leftMouseDown, .rightMouseDown:
            let button: MouseButton = type == .rightMouseDown ? .right : .left
            let click = ClickEvent(timestamp: timestamp, location: local, button: button)

            lock.lock()
            events.append(click)
            lock.unlock()

            onEvent?(click)

        case .mouseMoved, .leftMouseDragged, .rightMouseDragged where trackCursor:
            guard timestamp - lastCursorSampleTime >= cursorSampleInterval else { return }
            lastCursorSampleTime = timestamp
            let cursor = CursorEvent(timestamp: timestamp, location: local)

            lock.lock()
            cursorEvents.append(cursor)
            lock.unlock()

        default:
            break
        }
    }

    /// Moves the capture origin to where the tracked window is now. Keeps the last known
    /// position if the window can't be found (closed, or on another Space).
    private func refreshWindowOrigin() {
        guard let trackedWindowID,
              let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(trackedWindowID))
                as? [[String: Any]])?.first,
              let bounds = Self.bounds(of: info)
        else { return }
        captureOrigin = bounds.origin
    }

    /// On-screen windows, front to back.
    private static func onScreenWindows() -> [WindowSnapshot] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard let number = info[kCGWindowNumber as String] as? NSNumber,
                  let bounds = bounds(of: info)
            else { return nil }
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            return WindowSnapshot(windowID: number.uint32Value, layer: layer, bounds: bounds)
        }
    }

    private static func bounds(of info: [String: Any]) -> CGRect? {
        guard let dictionary = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }

    private func convertToCaptureCoordinates(global: CGPoint) -> CGPoint {
        CaptureGeometry.capturePoint(
            global: global,
            origin: captureOrigin,
            scale: scaleFactor,
            pixelHeight: captureSize.height
        )
    }
}

enum InputTrackerError: LocalizedError {
    case accessibilityRequired

    var errorDescription: String? {
        switch self {
        case .accessibilityRequired:
            return "Accessibility permission is required to track mouse clicks for automatic zoom."
        }
    }
}
