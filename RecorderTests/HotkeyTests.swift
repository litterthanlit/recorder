import Foundation
import Testing
@testable import RecorderCore

@Suite("Hotkeys")
struct HotkeyTests {
    private let command = KeyCombo.Modifier.command
    private let shift = KeyCombo.Modifier.shift
    private let option = KeyCombo.Modifier.option
    private let control = KeyCombo.Modifier.control

    @Test func displaysModifiersInMenuOrder() {
        let combo = KeyCombo(keyCode: KeyNames.Code.r, modifiers: command | shift | option | control)
        #expect(combo.displayString == "⌃⌥⇧⌘R")
        #expect(KeyCombo(keyCode: KeyNames.Code.period, modifiers: command | shift).displayString == "⇧⌘.")
    }

    @Test func namesSpecialKeys() {
        #expect(KeyCombo(keyCode: 0x60, modifiers: 0).displayString == "F5")
        #expect(KeyCombo(keyCode: KeyNames.Code.leftArrow, modifiers: option).displayString == "⌥←")
        #expect(KeyCombo(keyCode: KeyNames.Code.space, modifiers: control).displayString == "⌃Space")
        #expect(KeyCombo(keyCode: 0xFF, modifiers: command).displayString == "⌘Key 255")
    }

    @Test func convertsFromCocoaFlags() {
        let flags = KeyCombo.CocoaModifier.command | KeyCombo.CocoaModifier.shift | (1 << 16) // plus Caps Lock
        let combo = KeyCombo(keyCode: UInt16(KeyNames.Code.r), cocoaFlags: flags)
        #expect(combo.modifiers == command | shift)
        #expect(combo.cocoaFlags == KeyCombo.CocoaModifier.command | KeyCombo.CocoaModifier.shift)
    }

    @Test func globalShortcutsNeedARealModifier() {
        #expect(KeyCombo(keyCode: KeyNames.Code.r, modifiers: command).isValidGlobal)
        #expect(KeyCombo(keyCode: KeyNames.Code.r, modifiers: control).isValidGlobal)
        #expect(!KeyCombo(keyCode: KeyNames.Code.r, modifiers: shift).isValidGlobal)
        #expect(!KeyCombo(keyCode: KeyNames.Code.r, modifiers: 0).isValidGlobal)
        #expect(KeyCombo(keyCode: 0x60, modifiers: 0).isValidGlobal) // F5
    }

    @Test func defaultsDontConflict() {
        #expect(HotkeyBindings.defaults.conflictingActions().isEmpty)
        #expect(HotkeyBindings.defaults[.record]?.displayString == "⇧⌘R")
        #expect(HotkeyBindings.defaults[.stop]?.displayString == "⇧⌘.")
        #expect(HotkeyBindings.defaults[.pauseResume]?.displayString == "⇧⌘,")
        #expect(HotkeyBindings.defaults[.restart] == nil)
    }

    @Test func findsConflicts() {
        var bindings = HotkeyBindings.defaults
        bindings[.restart] = bindings[.record]
        #expect(bindings.conflictingActions() == [.record, .restart])
        #expect(bindings.action(using: bindings[.record]!, except: .restart) == .record)
        #expect(bindings.action(using: bindings[.stop]!, except: .stop) == nil)
    }

    @Test func registersOnlyWhatTheStateNeeds() {
        #expect(HotkeyBindings.activeActions(in: .idle) == [.record])
        #expect(HotkeyBindings.activeActions(in: .countdown) == [.stop])
        #expect(Set(HotkeyBindings.activeActions(in: .recording)) == [.stop, .pauseResume, .restart])
    }

    @Test func codableKeepsClearedShortcutsAndFillsNewOnes() throws {
        var bindings = HotkeyBindings.defaults
        bindings[.pauseResume] = nil
        bindings[.restart] = KeyCombo(keyCode: 0x60, modifiers: 0)
        let data = try JSONEncoder().encode(bindings)
        #expect(try JSONDecoder().decode(HotkeyBindings.self, from: data) == bindings)

        // Saved before "restart" existed: it gets its default (none); "stop" was cleared.
        let older = """
        { "record": { "keyCode": 15, "modifiers": 768 }, "stop": null, "pauseResume": null }
        """
        let decoded = try JSONDecoder().decode(HotkeyBindings.self, from: Data(older.utf8))
        #expect(decoded[.record] == HotkeyBindings.defaults[.record])
        #expect(decoded[.stop] == nil)
        #expect(decoded[.restart] == nil)
    }

    @Test func appSettingsDecodeWithDefaults() throws {
        let json = """
        { "afterRecording": "somethingNew", "playSounds": false }
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(settings.afterRecording == .quickAccess)
        #expect(settings.playSounds == false)
        #expect(settings.showRecordingHUD)
        #expect(settings.hotkeys == .defaults)

        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(roundTrip == settings)
    }
}
