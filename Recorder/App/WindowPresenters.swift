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
        // the view's reference to the editor.
        windowController?.window?.contentViewController = nil
        onClose?(editor.project.metadata.id)
    }

    func present(editor: ProjectEditor, onExported: @escaping (RecorderProject) -> Void) {
        presentedEditor = editor
        let rootView = EditorView(editor: editor)
            .onChange(of: editor.state) { _, newState in
                if case .exported = newState {
                    onExported(editor.project)
                }
            }

        if let window = windowController?.window {
            window.contentViewController = NSHostingController(rootView: rootView)
            window.makeKeyAndOrderFront(nil)
        } else {
            let hosting = NSHostingController(rootView: rootView)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Edit Recording"
            window.setContentSize(NSSize(width: 1100, height: 860))
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.identifier = ActivationPolicyController.identifier("editor")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            let controller = NSWindowController(window: window)
            controller.showWindow(nil)
            windowController = controller
        }

        NSApp.activate()
    }
}
