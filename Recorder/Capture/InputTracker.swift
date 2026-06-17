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

    var onEvent: ((ClickEvent) -> Void)?

    func configure(
        startTime: TimeInterval,
        captureOrigin: CGPoint,
        captureSize: CGSize,
        scaleFactor: CGFloat
    ) {
        self.startTime = startTime
        self.captureOrigin = captureOrigin
        self.captureSize = captureSize
        self.scaleFactor = scaleFactor
        events = []
    }

    func start() throws {
        guard eventTap == nil else { return }

        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let tracker = Unmanaged<InputTracker>.fromOpaque(userInfo).takeUnretainedValue()
            tracker.handle(event: event, type: type)
            return Unmanaged.passUnretained(event)
        }

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
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
    }

    func stop() -> [ClickEvent] {
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
        return events
    }

    private func handle(event: CGEvent, type: CGEventType) {
        let timestamp = CACurrentMediaTime() - startTime
        let global = event.location
        let local = convertToCaptureCoordinates(global: global)

        guard captureSize.width > 0, captureSize.height > 0 else { return }
        guard local.x >= 0, local.y >= 0, local.x <= captureSize.width, local.y <= captureSize.height else {
            return
        }

        let button: MouseButton = type == .rightMouseDown ? .right : .left
        let click = ClickEvent(timestamp: timestamp, location: local, button: button)

        lock.lock()
        events.append(click)
        lock.unlock()

        onEvent?(click)
    }

    private func convertToCaptureCoordinates(global: CGPoint) -> CGPoint {
        let relativeX = (global.x - captureOrigin.x) * scaleFactor
        let relativeYFromTop = (global.y - captureOrigin.y) * scaleFactor
        let flippedY = captureSize.height - relativeYFromTop
        return CGPoint(x: relativeX, y: flippedY)
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
