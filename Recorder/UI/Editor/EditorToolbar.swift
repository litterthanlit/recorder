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
        var identifiers: [NSToolbarItem.Identifier] = [.editorName, .flexibleSpace, .editorShape, .flexibleSpace, .editorHistory]
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
            .frame(width: 220)
            .focused($isFocused)
            .onAppear { name = editor.displayName }
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
        editor.rename(to: name)
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
        } label: {
            Label(editor.editSettings.canvas.aspect.label, systemImage: "aspectratio")
                .labelStyle(.titleAndIcon)
                .font(DS.Typeface.body)
        }
        .fixedSize()
        .help("Shape of the video")
        .accessibilityLabel("Video shape, \(editor.editSettings.canvas.aspect.label)")
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
        guard let window, event.window === window, window.isKeyWindow else { return false }
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
        if responder is NSControl, Self.controlKeys.contains(event.keyCode) {
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
