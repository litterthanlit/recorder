import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Everything tracked during a take.
struct InputTrackingResult {
    var clicks: [ClickEvent] = []
    var cursor: [CursorEvent] = []
    var keystrokes: [KeystrokeEvent] = []
    var cursorKinds: [CursorKindEvent] = []
}

final class InputTracker {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Key presses have their own tap: it needs Input Monitoring, and if that's missing,
    /// click tracking (and auto zoom) must still work.
    private var keyTap: CFMachPort?
    private var keyRunLoopSource: CFRunLoopSource?
    private var trackKeystrokes = false
    private var keystrokes: [KeystrokeEvent] = []
    private let cursorKindSampler = CursorKindSampler()
    private var clock: RecordingClock?
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

    /// - Parameter clock: the take's clock; events before t = 0 or while paused are dropped.
    func configure(
        clock: RecordingClock,
        captureOrigin: CGPoint,
        captureSize: CGSize,
        scaleFactor: CGFloat,
        trackCursor: Bool = true,
        trackKeystrokes: Bool = false,
        trackedWindowID: UInt32? = nil
    ) {
        self.clock = clock
        self.captureOrigin = captureOrigin
        self.captureSize = captureSize
        self.scaleFactor = scaleFactor
        self.trackCursor = trackCursor
        self.trackKeystrokes = trackKeystrokes
        self.trackedWindowID = trackedWindowID
        events = []
        cursorEvents = []
        keystrokes = []
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

        if trackCursor, let clock {
            cursorKindSampler.start(clock: clock)
        }
        if trackKeystrokes {
            startKeyTap()
        }

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

    func stop() -> InputTrackingResult {
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
        if let keyTap {
            CGEvent.tapEnable(tap: keyTap, enable: false)
        }
        if let keyRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), keyRunLoopSource, .commonModes)
        }
        keyTap = nil
        keyRunLoopSource = nil
        let cursorKinds = cursorKindSampler.stop()

        lock.lock()
        defer { lock.unlock() }
        return InputTrackingResult(clicks: events, cursor: cursorEvents, keystrokes: keystrokes, cursorKinds: cursorKinds)
    }

    private func startKeyTap() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let tracker = Unmanaged<InputTracker>.fromOpaque(userInfo).takeUnretainedValue()
            tracker.handleKey(event: event, type: type)
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.capture.warning("Keystrokes aren't recorded: the key tap needs Input Monitoring access")
            return
        }
        keyTap = tap
        keyRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), keyRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleKey(event: CGEvent, type: CGEventType) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let keyTap {
                CGEvent.tapEnable(tap: keyTap, enable: true)
            }
            return
        }
        guard type == .keyDown,
              // Holding a key down repeats it; show it once.
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
              // A password field is focused: never record what's typed there.
              !IsSecureEventInputEnabled(),
              let timestamp = clock?.recordingSeconds(forHostSeconds: CACurrentMediaTime())
        else { return }

        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = KeyCombo(
            keyCode: UInt16(truncatingIfNeeded: keyCode),
            cocoaFlags: UInt(event.flags.rawValue)
        ).modifiers
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: characters.count, actualStringLength: &length, unicodeString: &characters)
        let typed = length > 0 ? String(utf16CodeUnits: characters, count: length) : nil

        let keystroke = KeystrokeEvent(timestamp: timestamp, keyCode: keyCode, modifiers: modifiers, characters: typed)
        lock.lock()
        keystrokes.append(keystroke)
        lock.unlock()
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

        guard let timestamp = clock?.recordingSeconds(forHostSeconds: CACurrentMediaTime()) else { return }
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

        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            guard trackCursor, timestamp - lastCursorSampleTime >= cursorSampleInterval else { return }
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
