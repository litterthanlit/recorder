import Combine
import Foundation
import ServiceManagement

/// The app-wide settings, saved to UserDefaults on every change.
@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            if settings != oldValue {
                settings.save()
            }
        }
    }

    init() {
        settings = AppSettings.load()
    }
}

/// "Open at login", through the system's Login Items list.
@MainActor
final class LaunchAtLogin: ObservableObject {
    @Published private(set) var isEnabled = false
    /// Registered, but switched off in System Settings > General > Login Items.
    @Published private(set) var requiresApproval = false
    @Published private(set) var lastError: String?

    init() {
        refresh()
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        requiresApproval = status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            // Typically an unsigned build, or one run from outside /Applications.
            lastError = error.localizedDescription
            Log.app.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
