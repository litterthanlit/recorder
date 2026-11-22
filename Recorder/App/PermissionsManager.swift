import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation

@MainActor
final class PermissionsManager: ObservableObject {
    static let shared = PermissionsManager()

    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasCameraPermission = false
    @Published private(set) var hasMicrophonePermission = false
    /// Needed only to show keystrokes in recordings (listening to key presses).
    @Published private(set) var hasInputMonitoringPermission = false
    /// Screen Recording was requested in this run. macOS usually reports it as granted
    /// only after the app restarts, so the setup guide offers to relaunch.
    @Published private(set) var didRequestScreenRecording = false

    var hasRequiredPermissions: Bool {
        hasScreenRecordingPermission && hasAccessibilityPermission
    }

    private var activeObserver: NSObjectProtocol?

    private init() {
        refresh()
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func refresh() {
        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
        hasAccessibilityPermission = AXIsProcessTrusted()
        hasCameraPermission = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        hasMicrophonePermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        hasInputMonitoringPermission = CGPreflightListenEventAccess()
    }

    func requestScreenRecordingPermission() {
        if !CGPreflightScreenCaptureAccess() {
            didRequestScreenRecording = true
            _ = CGRequestScreenCaptureAccess()
        }
        refresh()
    }

    func requestInputMonitoringPermission() {
        if !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
        }
        refresh()
    }

    /// Quits and opens the app again, which is when a new Screen Recording permission
    /// takes effect. Waits for the current PID to exit before launching a fresh instance.
    func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open -n \"$2\"",
            "relaunch",
            String(pid),
            Bundle.main.bundleURL.path
        ]
        do {
            try process.run()
        } catch {
            Log.permissions.error("Relaunch failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        NSApp.terminate(nil)
    }

    func requestAccessibilityPermission() {
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        refresh()
    }

    func requestCameraPermission() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        refresh()
    }

    func requestMicrophonePermission() async {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
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
        case .camera:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                NSWorkspace.shared.open(url)
            }
        case .microphone:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        case .inputMonitoring:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

enum PermissionType {
    case screenRecording
    case accessibility
    case camera
    case microphone
    case inputMonitoring
}
