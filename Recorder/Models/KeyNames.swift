import Foundation

/// Display names for macOS virtual key codes (`kVK_…`), as they appear in menus.
/// Letters and punctuation follow the US layout; that's what shortcut labels in the app
/// use. The keystroke overlay prefers the characters recorded with each key press.
enum KeyNames {
    static func name(for keyCode: UInt32) -> String? {
        table[keyCode]
    }

    static func isFunctionKey(_ keyCode: UInt32) -> Bool {
        functionKeys.contains(keyCode)
    }

    /// Keys that type text (letters, digits, punctuation, space), as opposed to
    /// navigation and editing keys.
    static func isCharacterKey(_ keyCode: UInt32) -> Bool {
        characterKeys[keyCode] != nil || keyCode == Code.space
    }

    enum Code {
        static let returnKey: UInt32 = 0x24
        static let tab: UInt32 = 0x30
        static let space: UInt32 = 0x31
        static let delete: UInt32 = 0x33
        static let escape: UInt32 = 0x35
        static let forwardDelete: UInt32 = 0x75
        static let leftArrow: UInt32 = 0x7B
        static let rightArrow: UInt32 = 0x7C
        static let downArrow: UInt32 = 0x7D
        static let upArrow: UInt32 = 0x7E
        static let period: UInt32 = 0x2F
        static let comma: UInt32 = 0x2B
        static let r: UInt32 = 0x0F
    }

    private static let characterKeys: [UInt32: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G", 0x06: "Z", 0x07: "X",
        0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y",
        0x11: "T", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=",
        0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]", 0x1F: "O", 0x20: "U",
        0x21: "[", 0x22: "I", 0x23: "P", 0x25: "L", 0x26: "J", 0x27: "'", 0x28: "K", 0x29: ";",
        0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".", 0x32: "`",
        0x41: ".", 0x43: "*", 0x45: "+", 0x4B: "/", 0x4E: "-", 0x51: "=",
        0x52: "0", 0x53: "1", 0x54: "2", 0x55: "3", 0x56: "4", 0x57: "5", 0x58: "6", 0x59: "7",
        0x5B: "8", 0x5C: "9"
    ]

    private static let specialKeys: [UInt32: String] = [
        0x24: "↩", 0x4C: "⌤", 0x30: "⇥", 0x31: "Space", 0x33: "⌫", 0x35: "⎋", 0x75: "⌦",
        0x73: "↖", 0x77: "↘", 0x74: "⇞", 0x79: "⇟",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑", 0x47: "⌧"
    ]

    private static let functionKeyNames: [UInt32: String] = [
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6", 0x62: "F7",
        0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12", 0x69: "F13", 0x6B: "F14",
        0x71: "F15", 0x6A: "F16", 0x40: "F17", 0x4F: "F18", 0x50: "F19", 0x5A: "F20"
    ]

    private static let functionKeys = Set(functionKeyNames.keys)

    private static let table: [UInt32: String] = characterKeys
        .merging(specialKeys) { first, _ in first }
        .merging(functionKeyNames) { first, _ in first }
}
