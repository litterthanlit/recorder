import AppKit
import SwiftUI

/// What the editor asks of the rest of the app.
struct EditorActions {
    var export: @MainActor () -> Void
    /// Close the editor and record again; `nil` hides Retake.
    var retake: (@MainActor () -> Void)?
}

extension NSToolbarItem.Identifier {
    static let editorName = NSToolbarItem.Identifier("trace.editor.name")
    static let editorShape = NSToolbarItem.Identifier("trace.editor.shape")
    static let editorPolish = NSToolbarItem.Identifier("trace.editor.polish")
    static let editorHistory = NSToolbarItem.Identifier("trace.editor.history")
    static let editorRetake = NSToolbarItem.Identifier("trace.editor.retake")
    static let editorExport = NSToolbarItem.Identifier("trace.editor.export")
}

/// The editor window's unified toolbar: the recording's name, the video's shape, undo
/// and redo, Retake and Export. Each item hosts a SwiftUI view that follows the editor,
/// so the window keeps native title bar behaviour (dragging, traffic lights, full screen).
@MainActor
final class EditorToolbarController: NSObject, NSToolbarDelegate {
    private let editor: ProjectEditor
    private let actions: EditorActions

    init(editor: ProjectEditor, actions: EditorActions) {
        self.editor = editor
        self.actions = actions
    }

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "trace.editor")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [.editorShape]
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var identifiers: [NSToolbarItem.Identifier] = [
            .editorName, .flexibleSpace, .editorShape, .flexibleSpace, .editorPolish, .editorHistory
        ]
        if actions.retake != nil {
            identifiers.append(.editorRetake)
        }
        identifiers.append(.editorExport)
        return identifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier {
        case .editorName:
            item.label = "Name"
            item.view = Self.hosting(EditorNameField(editor: editor))
        case .editorShape:
            item.label = "Shape"
            item.view = Self.hosting(CanvasShapeMenu(editor: editor))
        case .editorPolish:
            item.label = "Polish"
            item.view = Self.hosting(PolishToolbarButton(editor: editor))
        case .editorHistory:
            item.label = "Undo"
            item.view = Self.hosting(UndoRedoButtons(editor: editor))
        case .editorRetake:
            item.label = "Retake"
            let retake = actions.retake
            item.view = Self.hosting(RetakeButton { retake?() })
        case .editorExport:
            item.label = "Export"
            item.view = Self.hosting(ExportToolbarButton(editor: editor, onExport: actions.export))
        default:
            return nil
        }
        return item
    }

    private static func hosting<Content: View>(_ view: Content) -> NSView {
        let hostingView = NSHostingView(rootView: view)
        hostingView.setFrameSize(hostingView.fittingSize)
        return hostingView
    }
}

/// The recording's name, editable in place.
private struct EditorNameField: View {
    @ObservedObject var editor: ProjectEditor
    @State private var name = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Recording name", text: $name)
            .textFieldStyle(.plain)
            .font(DS.Typeface.headline)
            .lineLimit(1)
            .padding(.horizontal, DS.Spacing.sm)
            .frame(width: 220, height: 28)
            .focused($isFocused)
            .onAppear { name = editor.displayName }
            .onChange(of: editor.displayName) { _, updated in
                if !isFocused {
                    name = updated
                }
            }
            .onSubmit(commit)
            .onChange(of: isFocused) { _, focused in
                if !focused {
                    commit()
                }
            }
            .help("Rename the recording")
            .accessibilityLabel("Recording name")
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == editor.displayName {
            name = editor.displayName
            return
        }
        editor.rename(to: trimmed)
        name = editor.displayName
    }
}

/// The video's shape (16:9, 9:16, …), the first thing to pick for where it's going.
private struct CanvasShapeMenu: View {
    @ObservedObject var editor: ProjectEditor

    var body: some View {
        Menu {
            Picker("Shape", selection: editor.settingBinding(\.canvas.aspect, actionName: "Change Shape")) {
                ForEach(OutputAspect.allCases) { aspect in
                    Text("\(aspect.label) — \(aspect.useCase)").tag(aspect)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Safe Zone Guides", isOn: $editor.showSafeZones)
        } label: {
            Label(editor.editSettings.canvas.aspect.label, systemImage: "aspectratio")
                .labelStyle(.titleAndIcon)
                .font(DS.Typeface.body)
        }
        .fixedSize()
        .help("Shape of the video and social safe-zone guides")
        .accessibilityLabel("Video shape, \(editor.editSettings.canvas.aspect.label)")
    }
}

/// One-click launch-demo pass: trims dead air, speeds through waits, adds auto zooms,
/// applies a social aspect + look + 3D tilt-in, all as one undo step.
private struct PolishToolbarButton: View {
    @ObservedObject var editor: ProjectEditor
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            if editor.isPolishing {
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Polishing…")
                }
            } else {
                Label("Polish", systemImage: "wand.and.stars")
                    .labelStyle(.titleAndIcon)
            }
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(editor.isExporting)
        .help("Auto-polish this recording into a social demo (one undo step)")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            PolishDemoPopover(editor: editor) {
                isPresented = false
            }
        }
    }
}

private struct PolishDemoPopover: View {
    @ObservedObject var editor: ProjectEditor
    @ObservedObject private var looks = StyleLibraryModel.shared
    let onDismiss: () -> Void

    @State private var target: ClipTarget = .xFeed
    @State private var pace: LaunchDemoPace = .snappy
    @State private var title = ""
    @State private var selectedLookID: UUID? = StylePreset.builtIn.first { $0.name == "Clean Studio" }?.id

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            Text("Polish for Socials")
                .font(DS.Typeface.headline)

            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text("Target")
                    .font(DS.Typeface.caption)
                    .foregroundStyle(DS.Palette.secondaryText)
                Picker("Target", selection: $target) {
                    ForEach(ClipTarget.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text("Pace")
                    .font(DS.Typeface.caption)
                    .foregroundStyle(DS.Palette.secondaryText)
                Picker("Pace", selection: $pace) {
                    Text("Relaxed").tag(LaunchDemoPace.relaxed)
                    Text("Snappy").tag(LaunchDemoPace.snappy)
                    Text("Punchy").tag(LaunchDemoPace.punchy)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text("Look")
                    .font(DS.Typeface.caption)
                    .foregroundStyle(DS.Palette.secondaryText)
                Picker("Look", selection: $selectedLookID) {
                    Text("Keep current").tag(UUID?.none)
                    ForEach(looks.library.allPresets) { preset in
                        Text(preset.name).tag(UUID?.some(preset.id))
                    }
                }
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text("Opening title (optional)")
                    .font(DS.Typeface.caption)
                    .foregroundStyle(DS.Palette.secondaryText)
                TextField("e.g. Ship faster with Trace", text: $title)
                    .textFieldStyle(.roundedBorder)
            }

            if let error = editor.polishError {
                Text(error)
                    .font(DS.Typeface.caption)
                    .foregroundStyle(DS.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if editor.isPolishing {
                ProgressView(value: editor.polishProgress)
                    .progressViewStyle(.linear)
            }

            HStack {
                Text("Single ⌘Z undoes everything.")
                    .font(DS.Typeface.caption)
                    .foregroundStyle(DS.Palette.secondaryText)
                Spacer()
                Button {
                    runPolish()
                } label: {
                    Label("Polish Demo", systemImage: "wand.and.stars")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(editor.isPolishing)
            }
        }
        .padding(DS.Spacing.md)
        .frame(width: 280)
    }

    private func runPolish() {
        let chosenLook = selectedLookID.flatMap { id in
            looks.library.allPresets.first { $0.id == id }
        }
        Task {
            let ok = await editor.polishForSocials(
                target: target,
                pace: pace,
                title: title,
                look: chosenLook
            )
            if ok {
                onDismiss()
            }
        }
    }
}

private struct UndoRedoButtons: View {
    @ObservedObject var editor: ProjectEditor

    var body: some View {
        HStack(spacing: 2) {
            Button {
                editor.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!editor.canUndo)
            .help(editor.undoActionName.map { "Undo \($0) (⌘Z)" } ?? "Nothing to undo")
            .accessibilityLabel(editor.undoActionName.map { "Undo \($0)" } ?? "Undo")

            Button {
                editor.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!editor.canRedo)
            .help(editor.redoActionName.map { "Redo \($0) (⇧⌘Z)" } ?? "Nothing to redo")
            .accessibilityLabel(editor.redoActionName.map { "Redo \($0)" } ?? "Redo")
        }
        .buttonStyle(IconButtonStyle())
    }
}

private struct RetakeButton: View {
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Label("Retake", systemImage: "arrow.counterclockwise")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(SecondaryButtonStyle())
        .help("Record this again. This take stays in your library.")
    }
}

/// Export, with progress while it runs and Show in Finder once it's done.
private struct ExportToolbarButton: View {
    @ObservedObject var editor: ProjectEditor
    let onExport: @MainActor () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            switch editor.state {
            case let .exporting(progress):
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                Text("Exporting \(Int((progress * 100).rounded()))%")
                    .font(DS.Typeface.footnote.monospacedDigit())
                    .foregroundStyle(DS.Palette.secondaryText)
                    .accessibilityLabel("Exporting, \(Int((progress * 100).rounded())) percent")
            case .exported:
                Button {
                    editor.revealExportInFinder()
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(SecondaryButtonStyle())
                exportButton
            case let .failed(message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DS.Palette.warning)
                    .help(message)
                    .accessibilityLabel("Export failed: \(message)")
                exportButton
            case .editing:
                exportButton
            }
        }
    }

    private var exportButton: some View {
        Button {
            onExport()
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(PrimaryButtonStyle())
        .help("Export the video (⌘E)")
    }
}

// MARK: - Keys

/// Sends the editor's single-key shortcuts to `handler` while its window is key.
/// Typing in a text field, and arrows or Space aimed at a focused control, are left
/// alone. `handler` returns whether it used the key.
struct EditorKeyCommands: NSViewRepresentable {
    let handler: @MainActor (EditorCommand) -> Bool

    func makeNSView(context: Context) -> EditorKeyCommandView {
        let view = EditorKeyCommandView()
        view.handler = handler
        return view
    }

    func updateNSView(_ nsView: EditorKeyCommandView, context: Context) {
        nsView.handler = handler
    }
}

final class EditorKeyCommandView: NSView {
    var handler: (@MainActor (EditorCommand) -> Bool)?
    private var monitor: Any?

    /// Space and the arrow keys.
    private static let controlKeys: Set<UInt16> = [0x31, 0x7B, 0x7C, 0x7D, 0x7E]

    deinit {
        removeMonitor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeMonitor()
        } else if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.handle(event) else { return event }
                return nil
            }
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.isKeyWindow, window.attachedSheet == nil else { return false }
        let responder = window.firstResponder
        // Typing in a text field (its field editor is an NSText).
        if responder is NSText {
            return false
        }
        let combo = KeyCombo(keyCode: event.keyCode, cocoaFlags: event.modifierFlags.rawValue)
        guard let command = EditorShortcuts.command(
            keyCode: combo.keyCode,
            modifiers: combo.modifiers,
            character: event.charactersIgnoringModifiers
        ) else { return false }
        let isFocusedControl = responder is NSControl || (responder as? NSView)?.canBecomeKeyView == true
        if isFocusedControl, Self.controlKeys.contains(event.keyCode) {
            return false
        }
        // Holding a key down repeats stepping and nudging, nothing else.
        if event.isARepeat {
            switch command {
            case .stepFrames, .stepSeconds, .nudgeSelection:
                break
            default:
                return true
            }
        }
        return handler?(command) ?? false
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}
