import AppKit
import Foundation

/// Auto-hides the Dock while recording and restores the user's setting afterwards.
///
/// The menu bar isn't hidden here: `NSApp.presentationOptions` only apply while this app
/// is frontmost, which it isn't while another app is being recorded. The recorder crops
/// the menu bar out instead (`ScreenRecorderOptions.cropsMenuBar`).
@MainActor
final class PresentationModeManager {
    private var isActive = false
    private var dockWasAutoHidden: Bool?

    func enter() {
        guard !isActive else { return }
        isActive = true

        // Read Dock prefs via System Events (app UserDefaults "autohide" is unrelated).
        if let current = readDockAutohide() {
            dockWasAutoHidden = current
            if !current {
                _ = setDockAutohide(true)
            }
        } else {
            dockWasAutoHidden = nil
        }
    }

    func exit() {
        guard isActive else { return }
        isActive = false

        if let dockWasAutoHidden {
            _ = setDockAutohide(dockWasAutoHidden)
            self.dockWasAutoHidden = nil
        }
    }

    private func readDockAutohide() -> Bool? {
        let script = """
        tell application "System Events"
            return autohide of dock preferences
        end tell
        """
        guard let appleScript = NSAppleScript(source: script) else { return nil }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return result.booleanValue
    }

    private func setDockAutohide(_ enabled: Bool) -> Bool {
        let value = enabled ? "true" : "false"
        let script = """
        tell application "System Events"
            set autohide of dock preferences to \(value)
        end tell
        """
        guard let appleScript = NSAppleScript(source: script) else { return false }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        return error == nil
    }
}
