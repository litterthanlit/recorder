import AppKit
import Combine
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    let session = RecordingSession()
    let permissions = PermissionsManager.shared
    let library = ProjectLibrary()

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
                switch state {
                case let .editing(project):
                    self.presentEditor(for: project)
                    self.library.refresh()
                case .finished:
                    self.library.refresh()
                default:
                    break
                }
            }
            .store(in: &cancellables)
    }

    /// Opens a project from the Recent list.
    func openProject(_ summary: ProjectSummary) {
        // If it's already open, use the editor's copy: it may have edits not saved yet.
        if let editor = session.editor(for: summary.id) {
            session.openProject(editor.project)
            return
        }

        let bundleURL = summary.bundleURL
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                try? ProjectStore.loadProject(from: bundleURL)
            }.value
            guard let loaded else {
                // Missing or damaged on disk; drop it from the list.
                library.refresh()
                return
            }
            session.openProject(loaded)
        }
    }

    /// Moves a project to the Trash, closing it first if it's open.
    func moveToTrash(_ summary: ProjectSummary) {
        guard !session.isBusy else { return }
        editorPresenter.close(projectID: summary.id)
        session.forgetProject(id: summary.id)
        do {
            try library.moveToTrash(summary)
        } catch {
            NSSound.beep()
            library.refresh()
        }
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
    private var presentedProjectID: UUID?

    /// Closes the editor window if it's showing this project, releasing its editor.
    func close(projectID: UUID) {
        guard presentedProjectID == projectID, let window = windowController?.window else { return }
        window.close()
        window.contentViewController = nil
        presentedProjectID = nil
    }

    func present(editor: ProjectEditor, onExported: @escaping (RecorderProject) -> Void) {
        presentedProjectID = editor.project.metadata.id
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
            window.setContentSize(NSSize(width: 1100, height: 860))
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
                library: appState.library,
                onOpenEditor: { project in
                    appState.presentEditor(for: project)
                },
                onOpenProject: { summary in
                    appState.openProject(summary)
                },
                onTrashProject: { summary in
                    appState.moveToTrash(summary)
                }
            )
        }
        .menuBarExtraStyle(.window)
    }
}
