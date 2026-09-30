import AppKit
import SwiftUI

/// Click, then press a key combination to set a global shortcut. Esc cancels, Delete
/// clears it. Combinations without ⌘, ⌃ or ⌥ (except F-keys) are refused with a beep,
/// since they'd swallow ordinary typing system-wide.
struct ShortcutRecorderField: NSViewRepresentable {
    @Binding var combo: KeyCombo?
    var onRecordingChange: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> ShortcutRecorderControl {
        let control = ShortcutRecorderControl()
        configure(control)
        return control
    }

    func updateNSView(_ control: ShortcutRecorderControl, context: Context) {
        configure(control)
    }

    private func configure(_ control: ShortcutRecorderControl) {
        let binding = $combo
        control.onChange = { binding.wrappedValue = $0 }
        control.onRecordingChange = onRecordingChange
        if !control.isRecording {
            control.combo = combo
        }
    }
}

final class ShortcutRecorderControl: NSView {
    var combo: KeyCombo? {
        didSet { refresh() }
    }
    var onChange: ((KeyCombo?) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?

    private(set) var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            liveModifiers = 0
            refresh()
            onRecordingChange?(isRecording)
        }
    }

    private var liveModifiers: UInt = 0
    private let label = NSTextField(labelWithString: "")
    private let clearButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1

        label.alignment = .center
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear shortcut")
        clearButton.isBordered = false
        clearButton.imageScaling = .scaleProportionallyDown
        clearButton.contentTintColor = .tertiaryLabelColor
        clearButton.target = self
        clearButton.action = #selector(clear)
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clearButton)

        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -2),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            clearButton.widthAnchor.constraint(equalToConstant: 14),
            clearButton.heightAnchor.constraint(equalToConstant: 14)
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 150, height: 24)
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if isRecording {
            window?.makeFirstResponder(nil)
        } else {
            window?.makeFirstResponder(self)
        }
    }

    override func becomeFirstResponder() -> Bool {
        isRecording = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    // Combinations with ⌘ arrive as key equivalents, before keyDown.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        handle(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        handle(event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else {
            super.flagsChanged(with: event)
            return
        }
        liveModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        refresh()
    }

    override func accessibilityPerformPress() -> Bool {
        window?.makeFirstResponder(self)
        return true
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let keyCode = UInt32(event.keyCode)
        if flags.isEmpty, keyCode == KeyNames.Code.escape {
            window?.makeFirstResponder(nil)
            return
        }
        if flags.isEmpty, keyCode == KeyNames.Code.delete || keyCode == KeyNames.Code.forwardDelete {
            clear()
            return
        }
        let candidate = KeyCombo(keyCode: event.keyCode, cocoaFlags: flags.rawValue)
        guard candidate.isValidGlobal else {
            NSSound.beep()
            return
        }
        combo = candidate
        onChange?(candidate)
        window?.makeFirstResponder(nil)
    }

    @objc private func clear() {
        combo = nil
        onChange?(nil)
        window?.makeFirstResponder(nil)
    }

    private func refresh() {
        let text: String
        if isRecording {
            let symbols = KeyCombo(keyCode: 0, cocoaFlags: liveModifiers).modifierSymbols
            text = symbols.isEmpty ? "Type shortcut…" : symbols
            label.textColor = .controlAccentColor
        } else if let combo {
            text = combo.displayString
            label.textColor = .labelColor
        } else {
            text = "Record Shortcut"
            label.textColor = .secondaryLabelColor
        }
        label.stringValue = text
        clearButton.isHidden = isRecording || combo == nil

        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        }
        setAccessibilityLabel(isRecording ? "Recording shortcut, press a key combination" : "Shortcut: \(combo?.displayString ?? "none")")
    }
}
