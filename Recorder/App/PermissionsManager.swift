import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
final class PermissionsManager: ObservableObject {
    static let shared = PermissionsManager()

    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasAccessibilityPermission = false

    var hasRequiredPermissions: Bool {
        hasScreenRecordingPermission && hasAccessibilityPermission
    }

    private init() {
        refresh()
    }

    func refresh() {
        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
        hasAccessibilityPermission = AXIsProcessTrusted()
    }

    func requestScreenRecordingPermission() {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        refresh()
    }

    func requestAccessibilityPermission() {
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        refresh()
    }

    func openSystemSettings(for permission: PermissionType) {
        switch permission {
        case .screenRecording:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        case .accessibility:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

enum PermissionType {
    case screenRecording
    case accessibility
}
