import AppKit
import Carbon.HIToolbox

/// System-wide ⌘⇧R / ⌘⇧. hotkeys.
///
/// Registered with `RegisterEventHotKey` rather than an `NSEvent` global monitor: a
/// monitor only observes keys, so ⌘⇧R would also reach the app being recorded (a hard
/// reload in Chrome, Reader in Safari). A registered hotkey is consumed, matches the exact
/// modifiers, and needs no Accessibility permission. Callbacks arrive on the main thread.
final class RecordingHotkeys {
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?

    private static let signature: OSType = 0x5243_5244 // "RCRD"

    private enum Hotkey: UInt32 {
        case start = 1
        case stop = 2
    }

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?

    deinit {
        stop()
    }

    func start() {
        stop()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == OSStatus(noErr), hotKeyID.signature == RecordingHotkeys.signature else {
                    return OSStatus(eventNotHandledErr)
                }

                let hotkeys = Unmanaged<RecordingHotkeys>.fromOpaque(userData).takeUnretainedValue()
                switch Hotkey(rawValue: hotKeyID.id) {
                case .start:
                    hotkeys.onStart?()
                case .stop:
                    hotkeys.onStop?()
                case nil:
                    return OSStatus(eventNotHandledErr)
                }
                return OSStatus(noErr)
            },
            1,
            &eventType,
            userData,
            &eventHandler
        )
        guard status == OSStatus(noErr) else { return }

        register(.start, keyCode: kVK_ANSI_R)
        register(.stop, keyCode: kVK_ANSI_Period)
    }

    func stop() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()

        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    private func register(_ hotkey: Hotkey, keyCode: Int) {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(cmdKey | shiftKey),
            EventHotKeyID(signature: Self.signature, id: hotkey.rawValue),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == OSStatus(noErr), let ref {
            hotKeyRefs.append(ref)
        }
    }
}

@MainActor
final class RecordingHotkeysController: ObservableObject {
    private let hotkeys = RecordingHotkeys()

    func bind(session: RecordingSession) {
        hotkeys.onStart = {
            Task { @MainActor in
                // `start()` ignores the key while a take is already in progress and
                // otherwise begins a new take from any state (including the editor).
                await session.start()
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
