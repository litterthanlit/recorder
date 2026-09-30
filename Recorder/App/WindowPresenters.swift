import AppKit
import SwiftUI

/// Owns one app window (settings, onboarding, library): creates it on first show,
/// brings it forward after that, and drops it when closed.
@MainActor
final class WindowPresenter: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let name: String
    private let title: String
    private let styleMask: NSWindow.StyleMask
    private let makeContent: () -> NSViewController
    var onClose: (() -> Void)?

    init(
        name: String,
        title: String,
        styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable],
        makeContent: @escaping () -> NSViewController
    ) {
        self.name = name
        self.title = title
        self.styleMask = styleMask
        self.makeContent = makeContent
    }

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: makeContent())
            window.title = title
            window.styleMask = styleMask
            window.identifier = ActivationPolicyController.identifier(name)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        window = nil
        onClose?()
    }
}

/// Opens the editor without depending on MenuBarView / openWindow lifecycle.
@MainActor
final class EditorPresenter: NSObject, NSWindowDelegate {
    private var windowController: NSWindowController?
    private var presentedEditor: ProjectEditor?
    private var toolbarController: EditorToolbarController?
    /// Called with the project ID after its editor window closes.
    var onClose: ((UUID) -> Void)?

    var isVisible: Bool {
        windowController?.window?.isVisible ?? false
    }

    /// Closes the editor window if it's showing this project, releasing its editor.
    func close(projectID: UUID) {
        guard presentedEditor?.project.metadata.id == projectID, let window = windowController?.window else { return }
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let editor = presentedEditor else { return }
        presentedEditor = nil
        editor.pausePlayback()
        editor.flushAutosave()
        // Takes the preview out of the window, which stops its display link, and drops
        // the views' references to the editor (the toolbar's too).
        windowController?.window?.contentViewController = nil
        windowController?.window?.toolbar = nil
        toolbarController = nil
        onClose?(editor.project.metadata.id)
    }

    /// - Parameter onRetake: closes the editor and records again; `nil` hides Retake.
    func present(
        editor: ProjectEditor,
        onExported: @escaping (RecorderProject) -> Void,
        onRetake: (@MainActor () -> Void)? = nil
    ) {
        presentedEditor = editor
        let actions = EditorActions(
            export: { [weak editor] in
                guard let editor else { return }
                Task { await editor.export() }
            },
            retake: onRetake
        )
        let rootView = EditorView(editor: editor, actions: actions)
            .onChange(of: editor.state) { _, newState in
                if case .exported = newState {
                    onExported(editor.project)
                }
            }
        let toolbarController = EditorToolbarController(editor: editor, actions: actions)
        self.toolbarController = toolbarController

        let window: NSWindow
        if let existing = windowController?.window {
            window = existing
            window.contentViewController = NSHostingController(rootView: rootView)
        } else {
            window = NSWindow(contentViewController: NSHostingController(rootView: rootView))
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.toolbarStyle = .unified
            window.titleVisibility = .hidden
            window.identifier = ActivationPolicyController.identifier("editor")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 1280, height: 840))
            window.center()
            window.setFrameAutosaveName("TraceEditorWindow")
            windowController = NSWindowController(window: window)
        }
        window.title = editor.displayName
        window.toolbar = toolbarController.makeToolbar()
        windowController?.showWindow(nil)
        window.makeKeyAndOrderFront(nil)

        NSApp.activate()
    }
}
