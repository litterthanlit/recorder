import AppKit
import Foundation

@MainActor
final class PresentationModeManager {
    private var previousPresentationOptions: NSApplication.PresentationOptions?
    private var dockWasAutoHidden: Bool?

    func enter() {
        guard previousPresentationOptions == nil else { return }

        previousPresentationOptions = NSApp.presentationOptions
        NSApp.presentationOptions = [
            .autoHideMenuBar,
            .autoHideDock,
            .fullScreen
        ]

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
        if let previousPresentationOptions {
            NSApp.presentationOptions = previousPresentationOptions
            self.previousPresentationOptions = nil
        }

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
