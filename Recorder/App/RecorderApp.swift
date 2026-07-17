import AppKit
import Combine
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    let session = RecordingSession()
    let permissions = PermissionsManager.shared

    private let hotkeys = RecordingHotkeysController()
    private let editorPresenter = EditorPresenter()
    private var cancellables = Set<AnyCancellable>()

    init() {
        // Bind at launch so ⌘⇧R / ⌘⇧. work before the menu panel is opened.
        hotkeys.bind(session: session)

        session.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                if case let .editing(project) = state {
                    self.presentEditor(for: project)
                }
            }
            .store(in: &cancellables)
    }

    func presentEditor(for project: RecorderProject) {
        session.openEditor(for: project)
        guard let editor = session.editor(for: project.metadata.id) else { return }
        editorPresenter.present(editor: editor) { [weak self] exported in
            self?.session.markExported(exported)
        }
    }
}

/// Opens the editor without depending on MenuBarView / openWindow lifecycle.
@MainActor
final class EditorPresenter {
    private var windowController: NSWindowController?

    func present(editor: ProjectEditor, onExported: @escaping (RecorderProject) -> Void) {
        let rootView = EditorView(editor: editor)
            .onChange(of: editor.state) { newState in
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
            window.setContentSize(NSSize(width: 820, height: 680))
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            let controller = NSWindowController(window: window)
            controller.showWindow(nil)
            windowController = controller
        }

        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct RecorderApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("Recorder", systemImage: "record.circle") {
            MenuBarView(
                session: appState.session,
                permissions: appState.permissions,
                onOpenEditor: { project in
                    appState.presentEditor(for: project)
                }
            )
        }
        .menuBarExtraStyle(.window)
    }
}
