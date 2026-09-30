import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) lazy var appState = AppState()
    private var statusItemController: StatusItemController?
    private let activationPolicy = ActivationPolicyController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItemController = StatusItemController(appState: appState)
        activationPolicy.start()
        appState.applicationDidFinishLaunching()
    }

    /// Opening the app again (Finder, Spotlight, the Dock icon) shows the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            appState.showPanel()
        }
        return true
    }
}
