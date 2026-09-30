import Foundation

/// A key plus modifiers, stored the way `RegisterEventHotKey` takes them (a virtual key
/// code and Carbon modifier bits), so it can be registered without conversion.
struct KeyCombo: Codable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    /// Carbon modifier masks (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`).
    enum Modifier {
        static let command: UInt32 = 1 << 8
        static let shift: UInt32 = 1 << 9
        static let option: UInt32 = 1 << 11
        static let control: UInt32 = 1 << 12
        static let all: UInt32 = command | shift | option | control
    }

    /// `NSEvent.ModifierFlags` raw values, for converting key events.
    enum CocoaModifier {
        static let shift: UInt = 1 << 17
        static let control: UInt = 1 << 18
        static let option: UInt = 1 << 19
        static let command: UInt = 1 << 20
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Modifier.all
    }

    /// From a key event: `keyCode` and `modifierFlags.rawValue`.
    init(keyCode: UInt16, cocoaFlags: UInt) {
        var modifiers: UInt32 = 0
        if cocoaFlags & CocoaModifier.command != 0 { modifiers |= Modifier.command }
        if cocoaFlags & CocoaModifier.shift != 0 { modifiers |= Modifier.shift }
        if cocoaFlags & CocoaModifier.option != 0 { modifiers |= Modifier.option }
        if cocoaFlags & CocoaModifier.control != 0 { modifiers |= Modifier.control }
        self.init(keyCode: UInt32(keyCode), modifiers: modifiers)
    }

    var cocoaFlags: UInt {
        var flags: UInt = 0
        if modifiers & Modifier.command != 0 { flags |= CocoaModifier.command }
        if modifiers & Modifier.shift != 0 { flags |= CocoaModifier.shift }
        if modifiers & Modifier.option != 0 { flags |= CocoaModifier.option }
        if modifiers & Modifier.control != 0 { flags |= CocoaModifier.control }
        return flags
    }

    /// Modifier symbols in the order macOS menus use: ⌃⌥⇧⌘.
    var modifierSymbols: String {
        var symbols = ""
        if modifiers & Modifier.control != 0 { symbols += "⌃" }
        if modifiers & Modifier.option != 0 { symbols += "⌥" }
        if modifiers & Modifier.shift != 0 { symbols += "⇧" }
        if modifiers & Modifier.command != 0 { symbols += "⌘" }
        return symbols
    }

    var keyName: String {
        KeyNames.name(for: keyCode) ?? "Key \(keyCode)"
    }

    /// "⌘⇧R" style, as shown in menus.
    var displayString: String {
        modifierSymbols + keyName
    }

    /// A system-wide shortcut needs ⌘, ⌃ or ⌥ (Shift alone would swallow typing), except
    /// for function keys, which are fine on their own.
    var isValidGlobal: Bool {
        if KeyNames.isFunctionKey(keyCode) { return true }
        return modifiers & (Modifier.command | Modifier.control | Modifier.option) != 0
    }
}

/// What a global shortcut does.
enum HotkeyAction: String, Codable, CaseIterable, Identifiable {
    case record
    case stop
    case pauseResume
    case restart

    var id: String { rawValue }

    var label: String {
        switch self {
        case .record: return "Start recording"
        case .stop: return "Stop or cancel recording"
        case .pauseResume: return "Pause or resume"
        case .restart: return "Restart recording"
        }
    }
}

/// When a shortcut is registered. Shortcuts that only make sense mid-take are registered
/// only then, so they don't take the combination away from other apps the rest of the time.
enum HotkeyContext: Equatable {
    case idle
    case countdown
    case recording
}

struct HotkeyBindings: Equatable {
    private(set) var combos: [HotkeyAction: KeyCombo]

    static let defaults = HotkeyBindings(combos: [
        .record: KeyCombo(keyCode: KeyNames.Code.r, modifiers: KeyCombo.Modifier.command | KeyCombo.Modifier.shift),
        .stop: KeyCombo(keyCode: KeyNames.Code.period, modifiers: KeyCombo.Modifier.command | KeyCombo.Modifier.shift),
        .pauseResume: KeyCombo(keyCode: KeyNames.Code.comma, modifiers: KeyCombo.Modifier.command | KeyCombo.Modifier.shift)
    ])

    init(combos: [HotkeyAction: KeyCombo]) {
        self.combos = combos
    }

    subscript(action: HotkeyAction) -> KeyCombo? {
        get { combos[action] }
        set { combos[action] = newValue }
    }

    /// Actions whose combination is also bound to another action.
    func conflictingActions() -> Set<HotkeyAction> {
        var byCombo: [KeyCombo: [HotkeyAction]] = [:]
        for (action, combo) in combos {
            byCombo[combo, default: []].append(action)
        }
        return Set(byCombo.values.filter { $0.count > 1 }.flatMap { $0 })
    }

    /// The action already using `combo`, other than `action`.
    func action(using combo: KeyCombo, except action: HotkeyAction) -> HotkeyAction? {
        HotkeyAction.allCases.first { $0 != action && combos[$0] == combo }
    }

    static func activeActions(in context: HotkeyContext) -> [HotkeyAction] {
        switch context {
        case .idle:
            return [.record]
        case .countdown:
            return [.stop]
        case .recording:
            return [.stop, .pauseResume, .restart]
        }
    }
}

// Stored as {"record": {...}, "restart": null}: a missing action gets its default (it was
// added after the settings were saved), null means the user cleared it.
extension HotkeyBindings: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let stored = try container.decode([String: KeyCombo?].self)
        var combos: [HotkeyAction: KeyCombo] = [:]
        for action in HotkeyAction.allCases {
            if let entry = stored[action.rawValue] {
                if let combo = entry {
                    combos[action] = combo
                }
            } else if let fallback = Self.defaults.combos[action] {
                combos[action] = fallback
            }
        }
        self.combos = combos
    }

    func encode(to encoder: Encoder) throws {
        var stored: [String: KeyCombo?] = [:]
        for action in HotkeyAction.allCases {
            stored[action.rawValue] = .some(combos[action])
        }
        var container = encoder.singleValueContainer()
        try container.encode(stored)
    }
}
