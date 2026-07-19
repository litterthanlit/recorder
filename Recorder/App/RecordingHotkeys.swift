import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class RecordingHotkeys {
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?

    func start() {
        stop()

        let handler: (NSEvent) -> Void = { [weak self] event in
            guard event.modifierFlags.contains([.command, .shift]) else { return }

            switch event.keyCode {
            case UInt16(kVK_ANSI_R):
                self?.onStart?()
            case UInt16(kVK_ANSI_Period):
                self?.onStop?()
            default:
                break
            }
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handler(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }
}

@MainActor
final class RecordingHotkeysController: ObservableObject {
    private let hotkeys = RecordingHotkeys()

    func bind(session: RecordingSession) {
        hotkeys.onStart = {
            Task { @MainActor in
                switch session.state {
                case .idle, .failed:
                    if case .failed = session.state {
                        session.reset()
                    }
                    await session.start()
                default:
                    break
                }
            }
        }
        hotkeys.onStop = {
            Task { @MainActor in
                switch session.state {
                case .countdown:
                    session.cancelCountdown()
                case .recording:
                    await session.stop()
                default:
                    break
                }
            }
        }
        hotkeys.start()
    }
}
