import Foundation
import Testing
@testable import RecorderCore

@Suite("Keystrokes")
struct KeystrokeTests {
    private let command = KeyCombo.Modifier.command
    private let shift = KeyCombo.Modifier.shift
    private let option = KeyCombo.Modifier.option
    private let control = KeyCombo.Modifier.control

    private func key(_ code: UInt32, _ modifiers: UInt32 = 0, _ characters: String? = nil) -> KeystrokeEvent {
        KeystrokeEvent(timestamp: 0, keyCode: code, modifiers: modifiers, characters: characters)
    }

    @Test func shortcutsReadLikeMenus() {
        #expect(key(0x28, command | shift, "k").label == "⇧⌘K")
        #expect(key(KeyNames.Code.leftArrow, control | option).label == "⌃⌥←")
        #expect(key(0x08, command, "c").label == "⌘C")
    }

    @Test func specialKeysUseSymbols() {
        #expect(key(KeyNames.Code.returnKey, 0, "\r").label == "↩")
        #expect(key(KeyNames.Code.tab, 0, "\t").label == "⇥")
        #expect(key(KeyNames.Code.escape, 0, "\u{1b}").label == "⎋")
        #expect(key(KeyNames.Code.delete, 0, "\u{7f}").label == "⌫")
        #expect(key(0x60).label == "F5")
        #expect(key(KeyNames.Code.space, 0, " ").label == "␣")
        #expect(key(KeyNames.Code.space, command, " ").label == "⌘Space")
    }

    @Test func typingKeepsTheTypedCharacter() {
        #expect(key(0x00, 0, "a").label == "a")
        #expect(key(0x00, shift, "A").label == "A")
        // A non-US layout: the key at US "Q" types "a" on AZERTY.
        #expect(key(0x0C, 0, "a").label == "a")
    }

    @Test func classifiesShortcutsAndTyping() {
        #expect(key(0x28, command, "k").isShortcut)
        #expect(key(KeyNames.Code.returnKey).isShortcut)
        #expect(!key(0x00, 0, "a").isShortcut)
        #expect(!key(0x00, shift, "A").isShortcut)
        #expect(KeystrokeFilter.shortcuts.includes(key(0x28, command, "k")))
        #expect(!KeystrokeFilter.shortcuts.includes(key(0x00, 0, "a")))
        #expect(KeystrokeFilter.all.includes(key(0x00, 0, "a")))
        #expect(!KeystrokeFilter.off.includes(key(0x28, command, "k")))
    }
}

@Suite("Cursor kinds")
struct CursorKindTests {
    @Test func looksUpTheShapeAtATime() {
        let events = [
            CursorKindEvent(timestamp: 1, kind: .iBeam),
            CursorKindEvent(timestamp: 3, kind: .pointingHand),
            CursorKindEvent(timestamp: 5, kind: .arrow)
        ]
        #expect(CursorKindTimeline.kind(at: 0.5, in: events) == .arrow)
        #expect(CursorKindTimeline.kind(at: 1, in: events) == .iBeam)
        #expect(CursorKindTimeline.kind(at: 2.9, in: events) == .iBeam)
        #expect(CursorKindTimeline.kind(at: 3.5, in: events) == .pointingHand)
        #expect(CursorKindTimeline.kind(at: 99, in: events) == .arrow)
        #expect(CursorKindTimeline.kind(at: 1, in: []) == .arrow)
    }

    @Test func storesOnlyChanges() {
        var events: [CursorKindEvent] = []
        CursorKindTimeline.append(.arrow, at: 0, to: &events)
        CursorKindTimeline.append(.iBeam, at: 1, to: &events)
        CursorKindTimeline.append(.iBeam, at: 2, to: &events)
        CursorKindTimeline.append(.arrow, at: 3, to: &events)
        #expect(events == [CursorKindEvent(timestamp: 1, kind: .iBeam), CursorKindEvent(timestamp: 3, kind: .arrow)])
    }

    @Test func inputLogDecodesTolerantly() throws {
        let json = #"{ "cursorKinds": [ { "timestamp": 1, "kind": "zoomIn" } ] }"#
        let log = try JSONDecoder().decode(InputLog.self, from: Data(json.utf8))
        #expect(log.keystrokes.isEmpty)
        #expect(log.cursorKinds == [CursorKindEvent(timestamp: 1, kind: .arrow)])
    }
}
