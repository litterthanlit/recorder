import Foundation

/// What happens when a take ends.
enum AfterRecordingAction: String, Codable, CaseIterable, Identifiable {
    /// A floating card with the take's thumbnail and quick actions (CleanShot style).
    case quickAccess
    /// Open the editor straight away.
    case openEditor

    var id: String { rawValue }

    var label: String {
        switch self {
        case .quickAccess: return "Show Quick Access overlay"
        case .openEditor: return "Open the editor"
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AfterRecordingAction(rawValue: raw) ?? .quickAccess
    }
}

/// App-wide settings (Settings window). Recording options live in `RecordingPreferences`.
struct AppSettings: Codable, Equatable {
    var afterRecording: AfterRecordingAction = .quickAccess
    /// The floating pill with timer, pause and stop while recording.
    var showRecordingHUD = true
    /// Start, stop and pause sounds.
    var playSounds = true
    /// Quick Access cards close themselves after a few seconds unless hovered.
    var quickAccessAutoDismiss = true
    var hotkeys: HotkeyBindings = .defaults
    var hasCompletedOnboarding = false

    static let `default` = AppSettings()
}

extension AppSettings {
    private enum CodingKeys: String, CodingKey {
        case afterRecording
        case showRecordingHUD
        case playSounds
        case quickAccessAutoDismiss
        case hotkeys
        case hasCompletedOnboarding
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        afterRecording = try container.decodeIfPresent(AfterRecordingAction.self, forKey: .afterRecording)
            ?? defaults.afterRecording
        showRecordingHUD = try container.decodeIfPresent(Bool.self, forKey: .showRecordingHUD) ?? defaults.showRecordingHUD
        playSounds = try container.decodeIfPresent(Bool.self, forKey: .playSounds) ?? defaults.playSounds
        quickAccessAutoDismiss = try container.decodeIfPresent(Bool.self, forKey: .quickAccessAutoDismiss)
            ?? defaults.quickAccessAutoDismiss
        hotkeys = (try? container.decodeIfPresent(HotkeyBindings.self, forKey: .hotkeys)) ?? defaults.hotkeys
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding)
            ?? defaults.hasCompletedOnboarding
    }

    private static let defaultsKey = "appSettings"

    static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return .default
        }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
