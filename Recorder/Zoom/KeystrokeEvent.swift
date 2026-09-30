import Foundation

/// One key press during a take, for the keystroke overlay.
struct KeystrokeEvent: Codable, Equatable {
    /// Seconds on the recording's timeline.
    let timestamp: TimeInterval
    /// Virtual key code (`kVK_…`).
    let keyCode: UInt32
    /// Modifiers held, as Carbon masks (`KeyCombo.Modifier`).
    let modifiers: UInt32
    /// What the key typed on the user's layout, when it types something.
    let characters: String?

    init(timestamp: TimeInterval, keyCode: UInt32, modifiers: UInt32, characters: String? = nil) {
        self.timestamp = timestamp
        self.keyCode = keyCode
        self.modifiers = modifiers & KeyCombo.Modifier.all
        self.characters = characters
    }

    /// ⌘, ⌃ or ⌥ held: a command rather than typing.
    var hasCommandModifier: Bool {
        modifiers & (KeyCombo.Modifier.command | KeyCombo.Modifier.control | KeyCombo.Modifier.option) != 0
    }

    /// A shortcut or a special key (Return, Tab, Esc, arrows, Delete, F-keys), as opposed
    /// to plain typing.
    var isShortcut: Bool {
        hasCommandModifier || !KeyNames.isCharacterKey(keyCode)
    }

    /// How the key is shown: "⌘⇧K", "⌥←", "↩", or the typed character for plain typing.
    var label: String {
        let modifierSymbols = KeyCombo(keyCode: keyCode, modifiers: modifiers).modifierSymbols
        if !hasCommandModifier, KeyNames.isCharacterKey(keyCode) {
            if keyCode == KeyNames.Code.space {
                return modifierSymbols + "␣"
            }
            // Typed text keeps its own case and layout (Shift is already in it).
            if let characters, !characters.isEmpty, characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                return characters
            }
        }
        let key: String
        if keyCode == KeyNames.Code.space {
            key = "Space"
        } else if hasCommandModifier, KeyNames.isCharacterKey(keyCode) {
            // Shortcuts read like menus: ⌘K, not ⌘k.
            key = KeyNames.name(for: keyCode) ?? (characters?.uppercased() ?? "?")
        } else {
            key = KeyNames.name(for: keyCode) ?? (characters ?? "?")
        }
        return modifierSymbols + key
    }
}

/// Which key presses the overlay shows.
enum KeystrokeFilter: String, Codable, CaseIterable, Identifiable {
    case off
    /// Shortcuts and special keys only; typing isn't shown.
    case shortcuts
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .shortcuts: return "Shortcuts only"
        case .all: return "All keys"
        }
    }

    func includes(_ event: KeystrokeEvent) -> Bool {
        switch self {
        case .off: return false
        case .shortcuts: return event.isShortcut
        case .all: return true
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = KeystrokeFilter(rawValue: raw) ?? .shortcuts
    }
}
