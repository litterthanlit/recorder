import AppKit

/// Shows the app in the Dock and the menu bar while one of its document-style windows
/// (editor, library, settings, onboarding) is open, and goes back to being a menu bar
/// extra when they're all closed. Besides ⌘-Tab, being a regular app gives the windows a
/// main menu, so ⌘C, ⌘V and ⌘Z work in their text fields.
@MainActor
final class ActivationPolicyController {
    /// Windows whose identifier starts with this count as document windows.
    static let identifierPrefix = "trace."

    private var observers: [NSObjectProtocol] = []

    func start() {
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.willCloseNotification
        ]
        for name in names {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // After the close finishes, so the closing window no longer counts.
                Task { @MainActor in self?.update() }
            }
            observers.append(observer)
        }
        update()
    }

    static func identifier(_ name: String) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier(identifierPrefix + name)
    }

    func update() {
        let hasDocumentWindow = NSApp.windows.contains { window in
            guard window.identifier?.rawValue.hasPrefix(Self.identifierPrefix) == true else { return false }
            return window.isVisible || window.isMiniaturized
        }
        let policy: NSApplication.ActivationPolicy = hasDocumentWindow ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if policy == .regular {
            NSApp.activate()
        }
    }
}
