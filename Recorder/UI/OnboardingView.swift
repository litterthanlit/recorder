import Combine
import SwiftUI

/// First-run setup: what Trace does, and the permissions it needs, with live status.
struct OnboardingView: View {
    let appState: AppState
    @ObservedObject private var permissions: PermissionsManager
    @ObservedObject private var settings: SettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(appState: AppState) {
        self.appState = appState
        permissions = appState.permissions
        settings = appState.settingsStore
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            hero

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                SectionHeader("Required")
                PermissionStep(
                    icon: "rectangle.dashed.badge.record",
                    title: "Screen Recording",
                    detail: "Capture a display, a window or an area of your screen.",
                    granted: permissions.hasScreenRecordingPermission,
                    grant: { permissions.requestScreenRecordingPermission() },
                    openSettings: { permissions.openSystemSettings(for: .screenRecording) },
                    relaunch: permissions.didRequestScreenRecording ? { permissions.relaunch() } : nil
                )
                PermissionStep(
                    icon: "cursorarrow.click.2",
                    title: "Accessibility",
                    detail: "Follow your clicks so the camera zooms in where the action is.",
                    granted: permissions.hasAccessibilityPermission,
                    grant: { permissions.requestAccessibilityPermission() },
                    openSettings: { permissions.openSystemSettings(for: .accessibility) }
                )
            }

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                SectionHeader("Optional")
                PermissionStep(
                    icon: "mic",
                    title: "Microphone",
                    detail: "Narrate your demo while you record.",
                    granted: permissions.hasMicrophonePermission,
                    grant: { Task { await permissions.requestMicrophonePermission() } },
                    openSettings: { permissions.openSystemSettings(for: .microphone) }
                )
                PermissionStep(
                    icon: "video",
                    title: "Camera",
                    detail: "Add a talking-head bubble you can move and resize later.",
                    granted: permissions.hasCameraPermission,
                    grant: { Task { await permissions.requestCameraPermission() } },
                    openSettings: { permissions.openSystemSettings(for: .camera) }
                )
                PermissionStep(
                    icon: "keyboard",
                    title: "Input Monitoring",
                    detail: "Show the shortcuts you press as on-screen keystrokes.",
                    granted: permissions.hasInputMonitoringPermission,
                    grant: { permissions.requestInputMonitoringPermission() },
                    openSettings: { permissions.openSystemSettings(for: .inputMonitoring) }
                )
            }

            footer
        }
        .padding(DS.Spacing.xl)
        .frame(width: 560)
        .onReceive(poll) { _ in permissions.refresh() }
        .onAppear { permissions.refresh() }
        .animation(DS.animation(reduceMotion: reduceMotion), value: permissions.hasRequiredPermissions)
    }

    private var hero: some View {
        HStack(spacing: DS.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [DS.Palette.accent, DS.Palette.accent.opacity(0.65)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "record.circle")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 60, height: 60)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text("Welcome to \(Brand.name)")
                    .font(DS.Typeface.display)
                Text(Brand.tagline)
                    .font(DS.Typeface.body)
                    .foregroundStyle(DS.Palette.secondaryText)
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .center) {
            if let record = settings.settings.hotkeys[.record] {
                HStack(spacing: DS.Spacing.xxs) {
                    Text("Record anytime with")
                    ShortcutBadge(text: record.displayString)
                }
                .font(DS.Typeface.footnote)
                .foregroundStyle(DS.Palette.secondaryText)
            }
            Spacer()
            Button(permissions.hasRequiredPermissions ? "Start Recording" : "Continue Without") {
                appState.finishOnboarding()
                if permissions.hasRequiredPermissions {
                    appState.showPanel()
                }
            }
            .buttonStyle(PrimaryButtonStyle(size: .regular))
            .keyboardShortcut(.defaultAction)
        }
    }
}

private struct PermissionStep: View {
    let icon: String
    let title: String
    let detail: String
    let granted: Bool
    let grant: () -> Void
    let openSettings: () -> Void
    var relaunch: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: DS.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(granted ? DS.Palette.success : DS.Palette.accent)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                        .fill((granted ? DS.Palette.success : DS.Palette.accent).opacity(0.12))
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DS.Typeface.headline)
                Text(detail)
                    .font(DS.Typeface.footnote)
                    .foregroundStyle(DS.Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: DS.Spacing.sm)

            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(DS.Typeface.footnote.weight(.medium))
                    .foregroundStyle(DS.Palette.success)
            } else if let relaunch {
                Button("Quit & Reopen", action: relaunch)
                    .buttonStyle(SecondaryButtonStyle())
                    .help("macOS applies Screen Recording access after \(Brand.name) restarts.")
            } else {
                HStack(spacing: DS.Spacing.xxs) {
                    Button("Allow…", action: grant)
                        .buttonStyle(SecondaryButtonStyle())
                    Button {
                        openSettings()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(IconButtonStyle())
                    .help("Open System Settings")
                    .accessibilityLabel("Open System Settings for \(title)")
                }
            }
        }
        .padding(DS.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                .fill(DS.Palette.raisedSurface)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(granted ? "allowed" : "not allowed")")
    }
}
