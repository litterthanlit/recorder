import AppKit
import SwiftUI

/// The Settings window: a toolbar-style tab view with one SwiftUI pane per tab.
enum SettingsWindow {
    @MainActor
    static func makeContent(appState: AppState) -> NSViewController {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(item("General", symbol: "gearshape", GeneralSettingsPane(
            appState: appState,
            settings: appState.settingsStore,
            launchAtLogin: appState.launchAtLogin,
            permissions: appState.permissions
        )))
        tabs.addTabViewItem(item("Recording", symbol: "record.circle", RecordingSettingsPane(
            session: appState.session,
            permissions: appState.permissions
        )))
        tabs.addTabViewItem(item("Shortcuts", symbol: "command", ShortcutsSettingsPane(
            settings: appState.settingsStore,
            hotkeys: appState.hotkeys
        )))
        tabs.addTabViewItem(item("Export", symbol: "square.and.arrow.up", ExportSettingsPane()))
        return tabs
    }

    @MainActor
    private static func item<Content: View>(_ label: String, symbol: String, _ view: Content) -> NSTabViewItem {
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = .preferredContentSize
        let item = NSTabViewItem(viewController: hosting)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
    }
}

private let paneWidth: CGFloat = 540

struct GeneralSettingsPane: View {
    let appState: AppState
    @ObservedObject var settings: SettingsStore
    @ObservedObject var launchAtLogin: LaunchAtLogin
    @ObservedObject var permissions: PermissionsManager

    var body: some View {
        Form {
            Section {
                Toggle("Open \(Brand.name) at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled || launchAtLogin.requiresApproval },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                if launchAtLogin.requiresApproval {
                    LabeledContent("Allow \(Brand.name) in System Settings to finish.") {
                        Button("Open Login Items…") { launchAtLogin.openLoginItemsSettings() }
                    }
                    .font(DS.Typeface.footnote)
                }
                if let error = launchAtLogin.lastError {
                    Text(error)
                        .font(DS.Typeface.footnote)
                        .foregroundStyle(DS.Palette.warning)
                }
            }

            Section {
                Picker("When a take ends", selection: $settings.settings.afterRecording) {
                    ForEach(AfterRecordingAction.allCases) { action in
                        Text(action.label).tag(action)
                    }
                }
                Toggle("Close Quick Access automatically", isOn: $settings.settings.quickAccessAutoDismiss)
                    .disabled(settings.settings.afterRecording != .quickAccess)
            } header: {
                Text("After recording")
            }

            Section {
                Toggle("Show recording controls", isOn: $settings.settings.showRecordingHUD)
                Toggle("Play sounds", isOn: $settings.settings.playSounds)
            } header: {
                Text("While recording")
            } footer: {
                Text("The controls float next to what you record and never appear in the video.")
            }

            Section {
                PermissionStatusRow(title: "Screen Recording", granted: permissions.hasScreenRecordingPermission)
                PermissionStatusRow(title: "Accessibility", granted: permissions.hasAccessibilityPermission)
                PermissionStatusRow(title: "Microphone", granted: permissions.hasMicrophonePermission, optional: true)
                PermissionStatusRow(title: "Camera", granted: permissions.hasCameraPermission, optional: true)
                PermissionStatusRow(title: "Input Monitoring", granted: permissions.hasInputMonitoringPermission, optional: true)
                Button("Open Setup Guide…") { appState.showOnboarding() }
            } header: {
                Text("Permissions")
            }

            Section {
                LabeledContent("Projects") {
                    HStack(spacing: DS.Spacing.xs) {
                        Text(ProjectStore.projectsDirectory.path(percentEncoded: false))
                            .font(DS.Typeface.footnote)
                            .foregroundStyle(DS.Palette.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Show in Finder") { appState.library.revealProjectsFolder() }
                    }
                }
            } header: {
                Text("Library")
            }
        }
        .formStyle(.grouped)
        .frame(width: paneWidth, height: 600)
        .onAppear {
            launchAtLogin.refresh()
            permissions.refresh()
        }
    }
}

struct PermissionStatusRow: View {
    let title: String
    let granted: Bool
    var optional = false

    var body: some View {
        LabeledContent {
            Label(
                granted ? "Allowed" : (optional ? "Not allowed" : "Required"),
                systemImage: granted ? "checkmark.circle.fill" : (optional ? "circle" : "exclamationmark.circle.fill")
            )
            .labelStyle(.titleAndIcon)
            .font(DS.Typeface.footnote)
            .foregroundStyle(granted ? DS.Palette.success : (optional ? DS.Palette.secondaryText : DS.Palette.warning))
        } label: {
            Text(title)
        }
        .accessibilityElement(children: .combine)
    }
}

struct RecordingSettingsPane: View {
    @ObservedObject var session: RecordingSession
    @ObservedObject var permissions: PermissionsManager

    private static let countdownChoices = [0, 3, 5, 10]

    var body: some View {
        Form {
            Section {
                Picker("Countdown", selection: $session.preferences.countdownSeconds) {
                    ForEach(Self.countdownChoices, id: \.self) { seconds in
                        Text(seconds == 0 ? "Off" : "\(seconds) seconds").tag(seconds)
                    }
                    if !Self.countdownChoices.contains(session.preferences.countdownSeconds) {
                        Text("\(session.preferences.countdownSeconds) seconds").tag(session.preferences.countdownSeconds)
                    }
                }
                Picker("Frame rate", selection: $session.preferences.frameRate) {
                    ForEach(RecordingPreferences.frameRateChoices, id: \.self) { fps in
                        Text("\(fps) fps").tag(fps)
                    }
                }
            } header: {
                Text("Capture")
            } footer: {
                Text("60 fps keeps scrolling and cursor movement smooth; 30 fps makes smaller files.")
            }

            Section {
                Toggle("Smooth cursor", isOn: $session.preferences.cursorSmoothingEnabled)
            } header: {
                Text("Cursor")
            } footer: {
                Text("Records the pointer's path and draws a smoothed cursor in the video instead of the real one, so it glides and lands exactly on each click.")
            }

            Section {
                Toggle("Show keystrokes", isOn: $session.preferences.recordKeystrokes)
                if session.preferences.recordKeystrokes && !permissions.hasInputMonitoringPermission {
                    LabeledContent("Needs Input Monitoring access") {
                        Button("Allow…") { permissions.requestInputMonitoringPermission() }
                    }
                    .font(DS.Typeface.footnote)
                }
            } header: {
                Text("Keyboard")
            } footer: {
                Text("Records the keys you press so shortcuts can be shown on screen in the editor. Nothing is recorded in password fields.")
            }

            Section {
                Toggle("Hide notifications", isOn: $session.preferences.hideNotifications)
                Toggle("Hide desktop icons", isOn: $session.preferences.hideDesktopIcons)
                Toggle("Hide menu bar and Dock", isOn: $session.preferences.hideChromeDuringRecording)
            } header: {
                Text("Clean screen")
            } footer: {
                Text("Notifications and desktop icons are left out of display and area recordings without changing your Mac's settings. Full-display recordings also leave out the menu bar, and the Dock hides while recording.")
            }
        }
        .formStyle(.grouped)
        .frame(width: paneWidth, height: 620)
        .onAppear { permissions.refresh() }
    }
}

struct ShortcutsSettingsPane: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var hotkeys: RecordingHotkeysController

    var body: some View {
        let conflicts = settings.settings.hotkeys.conflictingActions()
        Form {
            Section {
                ForEach(HotkeyAction.allCases) { action in
                    LabeledContent(action.label) {
                        HStack(spacing: DS.Spacing.xs) {
                            if conflicts.contains(action) {
                                warning("Also used by another action")
                            } else if hotkeys.failedActions.contains(action) {
                                warning("Another app is using this shortcut")
                            }
                            ShortcutRecorderField(combo: binding(for: action)) { isRecording in
                                if isRecording {
                                    hotkeys.suspend()
                                } else {
                                    hotkeys.resume()
                                }
                            }
                            .frame(width: 160, height: 24)
                        }
                    }
                }
            } header: {
                Text("Global shortcuts")
            } footer: {
                Text("Stop, pause and restart work only while recording, so they don't take those keys away from other apps the rest of the time.")
            }

            Section {
                Button("Restore Defaults") {
                    settings.settings.hotkeys = .defaults
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: paneWidth, height: 360)
    }

    private func binding(for action: HotkeyAction) -> Binding<KeyCombo?> {
        Binding(
            get: { settings.settings.hotkeys[action] },
            set: { settings.settings.hotkeys[action] = $0 }
        )
    }

    private func warning(_ message: String) -> some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(DS.Palette.warning)
            .help(message)
            .accessibilityLabel(message)
    }
}

struct ExportSettingsPane: View {
    @State private var preferences = ExportPreferences.load()

    private var folderText: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = preferences.folderURL.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    var body: some View {
        Form {
            Section {
                Picker("Format", selection: $preferences.options.format) {
                    ForEach(ExportFormat.allCases) { format in
                        Text("\(format.label) — \(format.detail)").tag(format)
                    }
                }
                Picker("Quality", selection: $preferences.options.quality) {
                    ForEach(ExportQuality.allCases) { quality in
                        Text(quality.label).tag(quality)
                    }
                }
                .disabled(!preferences.options.format.usesQuality)
                Picker("Frame rate", selection: $preferences.options.frameRate) {
                    Text("As recorded").tag(Int?.none)
                    ForEach(ExportOptions.frameRateChoices, id: \.self) { rate in
                        Text("\(rate) fps").tag(Int?.some(rate))
                    }
                }
                .disabled(preferences.options.format == .gif)
            } header: {
                Text("Default format")
            } footer: {
                Text("Quick Access exports with these, and the editor's Export sheet starts with them.")
            }

            Section {
                LabeledContent("Folder") {
                    HStack(spacing: DS.Spacing.xs) {
                        Text(folderText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Change…") { chooseFolder() }
                        Button("Show") {
                            try? FileManager.default.createDirectory(at: preferences.folderURL, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(preferences.folderURL)
                        }
                    }
                }
                Toggle("Ask where to save each time", isOn: $preferences.askForLocation)
                TextField("File name", text: $preferences.fileNameTemplate)
                Toggle("Show in Finder when an export finishes", isOn: $preferences.revealWhenDone)
            } header: {
                Text("Saving")
            } footer: {
                Text("File names can use {name}, {date} and {time}. An export never replaces a file already in the folder.")
            }
        }
        .formStyle(.grouped)
        .frame(width: paneWidth, height: 440)
        .onChange(of: preferences) { _, newValue in
            newValue.save()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = preferences.folderURL
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preferences.folderPath = url.path
    }
}
