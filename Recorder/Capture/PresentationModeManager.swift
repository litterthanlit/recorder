import AppKit
import Foundation

/// Auto-hides the Dock while recording and restores the user's setting afterwards.
///
/// The menu bar isn't hidden here: `NSApp.presentationOptions` only apply while this app
/// is frontmost, which it isn't while another app is being recorded. The recorder crops
/// the menu bar out instead (`ScreenRecorderOptions.cropsMenuBar`).
@MainActor
final class PresentationModeManager {
    private static let restoreDefaultsKey = "presentationMode.dockAutohideRestoreValue"
    private static let scriptQueue = DispatchQueue(label: "com.recorder.presentation-mode")

    private var isActive = false

    /// Restores the Dock's auto-hide preference if a previous session crashed or was
    /// force-quit while presentation mode was active.
    static func recoverDockIfNeeded(defaults: UserDefaults = .standard) {
        guard let saved = defaults.object(forKey: restoreDefaultsKey) as? Bool else { return }
        scriptQueue.async {
            if setDockAutohide(saved) {
                defaults.removeObject(forKey: restoreDefaultsKey)
            }
        }
    }

    func enter() {
        guard !isActive else { return }
        isActive = true

        // Run AppleScript off the main thread so a first-run Automation TCC prompt
        // never deadlocks the UI.
        Self.scriptQueue.async {
            guard let current = Self.readDockAutohide() else { return }
            guard !current else { return }
            UserDefaults.standard.set(current, forKey: Self.restoreDefaultsKey)
            if !Self.setDockAutohide(true) {
                UserDefaults.standard.removeObject(forKey: Self.restoreDefaultsKey)
            }
        }
    }

    func exit() {
        guard isActive else { return }
        isActive = false

        Self.scriptQueue.async {
            Self.restoreDockIfSaved()
        }
    }

    /// Blocks briefly during app termination so the Dock is restored before process exit.
    func exitSynchronously() {
        isActive = false
        Self.scriptQueue.sync {
            Self.restoreDockIfSaved()
        }
    }

    private nonisolated static func restoreDockIfSaved() {
        guard let saved = UserDefaults.standard.object(forKey: restoreDefaultsKey) as? Bool else { return }
        if setDockAutohide(saved) {
            UserDefaults.standard.removeObject(forKey: restoreDefaultsKey)
        }
    }

    private nonisolated static func readDockAutohide() -> Bool? {
        let script = """
        tell application "System Events"
            return autohide of dock preferences
        end tell
        """
        guard let appleScript = NSAppleScript(source: script) else { return nil }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        if let error {
            Log.capture.error("Reading the Dock setting failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        return result.booleanValue
    }

    private nonisolated static func setDockAutohide(_ enabled: Bool) -> Bool {
        let value = enabled ? "true" : "false"
        let script = """
        tell application "System Events"
            set autohide of dock preferences to \(value)
        end tell
        """
        guard let appleScript = NSAppleScript(source: script) else { return false }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        if let error {
            Log.capture.error("Changing the Dock setting failed: \(String(describing: error), privacy: .public)")
            return false
        }
        return true
    }
}
