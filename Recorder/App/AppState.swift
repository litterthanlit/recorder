import AppKit
import Combine
import SwiftUI

/// Owns the app's long-lived objects and the windows that aren't the menu bar panel.
@MainActor
final class AppState: ObservableObject {
    let session: RecordingSession
    let permissions = PermissionsManager.shared
    let library: ProjectLibrary
    let settingsStore: SettingsStore
    let launchAtLogin = LaunchAtLogin()
    let hotkeys = RecordingHotkeysController()

    /// Set by the status item: open and close the menu bar panel.
    var showPanelHandler: (() -> Void)?
    var dismissPanelHandler: (() -> Void)?

    private let editorPresenter = EditorPresenter()
    private lazy var settingsPresenter = WindowPresenter(
        name: "settings",
        title: "\(Brand.name) Settings"
    ) { [unowned self] in
        SettingsWindow.makeContent(appState: self)
    }
    private lazy var onboardingPresenter = WindowPresenter(
        name: "onboarding",
        title: "Welcome to \(Brand.name)",
        styleMask: [.titled, .closable, .fullSizeContentView]
    ) { [unowned self] in
        let hosting = NSHostingController(rootView: OnboardingView(appState: self))
        hosting.sizingOptions = .preferredContentSize
        return hosting
    }
    private var cancellables = Set<AnyCancellable>()

    init() {
        // Before anything lists or writes projects.
        LibraryMigration.migrateDefaultLibrary()
        settingsStore = SettingsStore()
        session = RecordingSession()
        library = ProjectLibrary()

        hotkeys.bind(session: session, settings: settingsStore) { [weak self] action in
            self?.handleHotkey(action)
        }
        editorPresenter.onClose = { [weak session] projectID in
            session?.releaseEditor(id: projectID)
        }
        onboardingPresenter.onClose = { [weak self] in
            self?.settingsStore.settings.hasCompletedOnboarding = true
        }

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

    func applicationDidFinishLaunching() {
        permissions.refresh()
        if !settingsStore.settings.hasCompletedOnboarding || !permissions.hasRequiredPermissions {
            showOnboarding()
        }
    }

    // MARK: - Actions

    /// Starts a take (from the panel, the status menu, or the record shortcut).
    func startRecording() {
        dismissPanel()
        guard permissions.hasRequiredPermissions else {
            permissions.refresh()
            if !permissions.hasRequiredPermissions {
                showOnboarding()
                return
            }
        }
        Task { await session.start() }
    }

    func showPanel() {
        showPanelHandler?()
    }

    func dismissPanel() {
        dismissPanelHandler?()
    }

    func showSettings() {
        dismissPanel()
        settingsPresenter.show()
    }

    func showOnboarding() {
        dismissPanel()
        onboardingPresenter.show()
    }

    func finishOnboarding() {
        settingsStore.settings.hasCompletedOnboarding = true
        onboardingPresenter.close()
    }

    func showLibrary() {
        dismissPanel()
        library.revealProjectsFolder()
    }

    private func handleHotkey(_ action: HotkeyAction) {
        switch action {
        case .record:
            startRecording()
        case .stop:
            switch session.state {
            case .countdown:
                session.cancelCountdown()
            case .recording:
                Task { await session.stop() }
            default:
                break
            }
        case .pauseResume, .restart:
            break
        }
    }

    // MARK: - Projects

    /// Opens a project from the Recent list.
    func openProject(_ summary: ProjectSummary) {
        dismissPanel()
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
        dismissPanel()
        session.openEditor(for: project)
        guard let editor = session.editor(for: project.metadata.id) else { return }
        editorPresenter.present(editor: editor) { [weak self] exported in
            self?.session.markExported(exported)
        }
    }
}
