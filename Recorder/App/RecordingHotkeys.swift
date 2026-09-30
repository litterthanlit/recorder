import AppKit
import Carbon.HIToolbox
import Combine

/// System-wide shortcuts, registered with `RegisterEventHotKey`.
///
/// A registered hotkey is consumed, so ⌘⇧R doesn't also reach the app being recorded (a
/// hard reload in Chrome, Reader in Safari), matches the exact modifiers, and needs no
/// Accessibility permission. Unlike an `NSEvent` monitor, it can't observe other keys.
/// Callbacks arrive on the main thread.
final class GlobalHotkeys {
    var onPress: ((HotkeyAction) -> Void)?

    private static let signature: OSType = 0x5243_5244 // "RCRD"

    private var eventHandler: EventHandlerRef?
    private var registered: [HotkeyAction: EventHotKeyRef] = [:]

    deinit {
        unregisterAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    /// Registers exactly `combos`, replacing whatever was registered before. Returns the
    /// actions that couldn't be registered (`eventHotKeyExistsErr`: another app has it).
    @discardableResult
    func apply(_ combos: [HotkeyAction: KeyCombo]) -> [HotkeyAction: OSStatus] {
        unregisterAll()
        guard installHandlerIfNeeded() else {
            return combos.mapValues { _ in OSStatus(eventNotHandledErr) }
        }

        var failures: [HotkeyAction: OSStatus] = [:]
        for (action, combo) in combos {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                combo.keyCode,
                combo.modifiers,
                EventHotKeyID(signature: Self.signature, id: Self.id(for: action)),
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == OSStatus(noErr), let ref {
                registered[action] = ref
            } else {
                failures[action] = status
            }
        }
        return failures
    }

    func unregisterAll() {
        for ref in registered.values {
            UnregisterEventHotKey(ref)
        }
        registered.removeAll()
    }

    private static func id(for action: HotkeyAction) -> UInt32 {
        UInt32((HotkeyAction.allCases.firstIndex(of: action) ?? 0) + 1)
    }

    private static func action(for id: UInt32) -> HotkeyAction? {
        let index = Int(id) - 1
        guard HotkeyAction.allCases.indices.contains(index) else { return nil }
        return HotkeyAction.allCases[index]
    }

    private func installHandlerIfNeeded() -> Bool {
        if eventHandler != nil { return true }

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
                guard status == OSStatus(noErr),
                      hotKeyID.signature == GlobalHotkeys.signature,
                      let action = GlobalHotkeys.action(for: hotKeyID.id)
                else {
                    return OSStatus(eventNotHandledErr)
                }

                let hotkeys = Unmanaged<GlobalHotkeys>.fromOpaque(userData).takeUnretainedValue()
                hotkeys.onPress?(action)
                return OSStatus(noErr)
            },
            1,
            &eventType,
            userData,
            &eventHandler
        )
        return status == OSStatus(noErr)
    }
}

/// Keeps the registered shortcuts in step with the bindings in Settings and the
/// recording state: only the shortcuts that do something right now are registered.
@MainActor
final class RecordingHotkeysController: ObservableObject {
    /// Active shortcuts that couldn't be registered (usually taken by another app).
    @Published private(set) var failedActions: Set<HotkeyAction> = []

    private let hotkeys = GlobalHotkeys()
    private var context: HotkeyContext = .idle
    private var bindings: HotkeyBindings = .defaults
    private var suspendCount = 0
    private var cancellables = Set<AnyCancellable>()

    func bind(
        session: RecordingSession,
        settings: SettingsStore,
        handler: @escaping (HotkeyAction) -> Void
    ) {
        hotkeys.onPress = { action in
            Task { @MainActor in handler(action) }
        }
        session.$state
            .map { Self.context(for: $0) }
            .removeDuplicates()
            .sink { [weak self] context in
                self?.context = context
                self?.refresh()
            }
            .store(in: &cancellables)
        settings.$settings
            .map(\.hotkeys)
            .removeDuplicates()
            .sink { [weak self] bindings in
                self?.bindings = bindings
                self?.refresh()
            }
            .store(in: &cancellables)
    }

    /// Stops all shortcuts while the Settings field records a new one, so pressing a
    /// combination that's already bound doesn't trigger it.
    func suspend() {
        suspendCount += 1
        refresh()
    }

    func resume() {
        suspendCount = max(0, suspendCount - 1)
        refresh()
    }

    private func refresh() {
        guard suspendCount == 0 else {
            hotkeys.unregisterAll()
            return
        }
        var combos: [HotkeyAction: KeyCombo] = [:]
        for action in HotkeyBindings.activeActions(in: context) {
            if let combo = bindings[action], combo.isValidGlobal {
                combos[action] = combo
            }
        }
        let failures = hotkeys.apply(combos)
        for (action, status) in failures {
            Log.hotkeys.error("Couldn't register \(action.rawValue, privacy: .public) (\(status))")
        }
        failedActions = Set(failures.keys)
    }

    private nonisolated static func context(for state: RecordingSession.State) -> HotkeyContext {
        switch state {
        case .countdown:
            return .countdown
        case .recording:
            return .recording
        case .idle, .processing, .editing, .finished, .failed:
            return .idle
        }
    }
}
