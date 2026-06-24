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

        dockWasAutoHidden = UserDefaults.standard.bool(forKey: "autohide")
        let script = """
        tell application "System Events"
            set autohide of dock preferences to true
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    func exit() {
        if let previousPresentationOptions {
            NSApp.presentationOptions = previousPresentationOptions
            self.previousPresentationOptions = nil
        }

        if let dockWasAutoHidden {
            let value = dockWasAutoHidden ? "true" : "false"
            let script = """
            tell application "System Events"
                set autohide of dock preferences to \(value)
            end tell
            """
            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
            }
            self.dockWasAutoHidden = nil
        }
    }
}
