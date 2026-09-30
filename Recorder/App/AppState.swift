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
    let captureSelector = CaptureSelector()
    private var recordingOverlays: RecordingOverlays?
    private var quickAccess: QuickAccessController?

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
    private lazy var libraryPresenter = WindowPresenter(
        name: "library",
        title: "\(Brand.name) Library",
        styleMask: [.titled, .closable, .miniaturizable, .resizable]
    ) { [unowned self] in
        let hosting = NSHostingController(rootView: LibraryView(appState: self))
        hosting.view.frame.size = CGSize(width: 960, height: 640)
        return hosting
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
        recordingOverlays = RecordingOverlays(session: session, settings: settingsStore)
        let quickAccess = QuickAccessController(library: library, settings: settingsStore)
        quickAccess.onEdit = { [weak self] project in
            self?.session.openProject(project)
        }
        self.quickAccess = quickAccess
        session.onTakeFinished = { [weak self] project in
            self?.handleFinishedTake(project)
        }
        settingsStore.$settings
            .map(\.playSounds)
            .removeDuplicates()
            .sink { [weak session] enabled in
                session?.soundsEnabled = enabled
            }
            .store(in: &cancellables)
        editorPresenter.onClose = { [weak session] projectID in
            session?.releaseEditor(id: projectID)
        }
        editorPresenter.onRename = { [weak self] in
            self?.library.refresh()
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

    /// Starts a take right away with the last target (display, window or area): a
    /// retake from the editor.
    func startRecording() {
        dismissPanel()
        guard ensurePermissions() else { return }
        Task { await session.start() }
    }

    /// Opens the selector to pick what to record, starting in `mode` (by default the kind
    /// recorded last). The last area is offered again, so a retake is ⇧⌘R then ⏎.
    func chooseAndRecord(mode: CaptureSelector.Mode? = nil) {
        dismissPanel()
        guard !session.isBusy, ensurePermissions() else { return }
        let preferences = session.preferences
        let initialMode = mode ?? {
            switch preferences.captureTarget {
            case .area: return .area
            case .window: return .window
            case .display: return .display
            }
        }()
        captureSelector.begin(
            mode: initialMode,
            lastArea: preferences.lastArea,
            preset: preferences.areaPreset
        ) { [weak self] selection in
            guard let self else { return }
            self.session.preferences.areaPreset = self.captureSelector.preset
            guard let selection else { return }
            switch selection {
            case let .area(area):
                self.session.preferences.captureTarget = .area
                self.session.preferences.lastArea = area
            case let .window(windowID):
                self.session.preferences.captureTarget = .window
                self.session.preferences.selectedWindowID = windowID
            case let .display(displayID):
                self.session.preferences.captureTarget = .display
                self.session.preferences.selectedDisplayID = displayID
            }
            Task { await self.session.start() }
        }
    }

    /// Screen Recording and Accessibility; opens the setup guide when missing.
    private func ensurePermissions() -> Bool {
        if !permissions.hasRequiredPermissions {
            // The cached status may be stale (just granted in System Settings).
            permissions.refresh()
            guard permissions.hasRequiredPermissions else {
                showOnboarding()
                return false
            }
        }
        return true
    }

    /// Records a display (`nil`: the one chosen before, or the main display).
    func startRecording(displayID: UInt32?) {
        session.preferences.captureTarget = .display
        if let displayID {
            session.preferences.selectedDisplayID = displayID
        }
        startRecording()
    }

    func startRecording(area: CaptureArea) {
        session.preferences.captureTarget = .area
        session.preferences.lastArea = area
        startRecording()
    }

    func startRecording(windowID: UInt32) {
        session.preferences.captureTarget = .window
        session.preferences.selectedWindowID = windowID
        startRecording()
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
        libraryPresenter.show()
    }

    /// A take was saved: open it in the editor, or offer it in a Quick Access card.
    private func handleFinishedTake(_ project: RecorderProject) {
        library.refresh()
        switch settingsStore.settings.afterRecording {
        case .openEditor:
            session.openProject(project)
        case .quickAccess:
            quickAccess?.show(project)
        }
    }

    private func handleHotkey(_ action: HotkeyAction) {
        switch action {
        case .record:
            if captureSelector.isActive {
                captureSelector.confirm()
            } else {
                chooseAndRecord()
            }
        case .stop:
            switch session.state {
            case .countdown:
                session.cancelCountdown()
            case .recording:
                Task { await session.stop() }
            default:
                break
            }
        case .pauseResume:
            session.togglePause()
        case .restart:
            Task { await session.restart() }
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
        let projectID = project.metadata.id
        editorPresenter.present(
            editor: editor,
            onExported: { [weak self] exported in
                self?.session.markExported(exported)
            },
            onRetake: { [weak self] in
                guard let self else { return }
                self.editorPresenter.close(projectID: projectID)
                self.chooseAndRecord()
            }
        )
    }
}
