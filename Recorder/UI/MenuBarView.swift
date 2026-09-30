import AppKit
import SwiftUI

/// The menu bar panel: pick what to record, toggle mic / camera / system audio, reopen a
/// recent take. While a take is running it turns into a timer with Stop.
struct MenuBarView: View {
    let appState: AppState
    @ObservedObject private var session: RecordingSession
    @ObservedObject private var permissions: PermissionsManager
    @ObservedObject private var library: ProjectLibrary
    @ObservedObject private var settings: SettingsStore

    init(appState: AppState) {
        self.appState = appState
        session = appState.session
        permissions = appState.permissions
        library = appState.library
        settings = appState.settingsStore
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, DS.Spacing.md)
                .padding(.top, DS.Spacing.md)
                .padding(.bottom, DS.Spacing.sm)

            content
                .padding(.horizontal, DS.Spacing.xs)
                .padding(.bottom, DS.Spacing.sm)

            Divider()

            footer
                .padding(.horizontal, DS.Spacing.xs)
                .padding(.vertical, DS.Spacing.xs)
        }
        .frame(width: 340)
        .onAppear {
            permissions.refresh()
            session.refreshMediaDevices()
            session.refreshDisplays()
            library.refresh()
            Task { await session.refreshWindows() }
        }
    }

    // MARK: - Header and footer

    private var header: some View {
        HStack(spacing: DS.Spacing.xs) {
            BrandMark(size: 22)
            Text(Brand.name)
                .font(DS.Typeface.title)
            Spacer()
            if case .recording = session.state {
                RecordingDot()
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 2) {
            footerButton("Library", icon: "square.grid.2x2") { appState.showLibrary() }
            footerButton("Settings", icon: "gearshape") { appState.showSettings() }
            Spacer()
            footerButton("Quit", icon: "power") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
    }

    private func footerButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(DS.Typeface.footnote)
                .foregroundStyle(DS.Palette.secondaryText)
        }
        .buttonStyle(HoverRowStyle())
        .fixedSize()
    }

    // MARK: - Content by state

    @ViewBuilder
    private var content: some View {
        switch session.state {
        case let .countdown(remaining):
            countdownStatus(remaining)
        case .recording:
            recordingStatus
        case .processing:
            processingStatus
        case .idle, .editing, .finished, .failed:
            if permissions.hasRequiredPermissions {
                idleContent
            } else {
                setupCard
            }
        }
    }

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            if let message = noticeText {
                NoticeBanner(message: message)
                    .padding(.horizontal, DS.Spacing.xs)
            }

            VStack(alignment: .leading, spacing: 2) {
                areaRow
                windowRow
                displayRow
            }

            devices
                .padding(.horizontal, DS.Spacing.xs)

            RecentProjectsView(
                library: library,
                onOpen: { appState.openProject($0) },
                onTrash: { appState.moveToTrash($0) },
                onShowAll: { appState.showLibrary() }
            )
            .padding(.horizontal, DS.Spacing.xxs)
        }
    }

    private var noticeText: String? {
        if case let .failed(message) = session.state {
            return message
        }
        return session.notice
    }

    // MARK: - Capture rows

    private var recordShortcut: String? {
        settings.settings.hotkeys[.record]?.displayString
    }

    @ViewBuilder
    private var displayRow: some View {
        let isLastUsed = session.preferences.captureTarget == .display
        if session.availableDisplays.count > 1 {
            Menu {
                ForEach(session.availableDisplays) { display in
                    Button(display.name) {
                        appState.startRecording(displayID: display.displayID)
                    }
                }
            } label: {
                CaptureRow(
                    icon: "display",
                    title: "Record Display",
                    subtitle: selectedDisplayName,
                    shortcut: isLastUsed ? recordShortcut : nil,
                    showsChevron: true
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .buttonStyle(HoverRowStyle())
        } else {
            Button {
                appState.startRecording(displayID: nil)
            } label: {
                CaptureRow(
                    icon: "display",
                    title: "Record Display",
                    subtitle: "The whole screen",
                    shortcut: isLastUsed ? recordShortcut : nil,
                    showsChevron: false
                )
            }
            .buttonStyle(HoverRowStyle())
        }
    }

    private var areaRow: some View {
        Button {
            appState.chooseAndRecord(mode: .area)
        } label: {
            CaptureRow(
                icon: "rectangle.dashed",
                title: "Record Area",
                subtitle: session.preferences.lastArea == nil ? "Drag out part of the screen" : "Draw a new area or reuse the last one",
                shortcut: session.preferences.captureTarget == .area ? recordShortcut : nil,
                showsChevron: false
            )
        }
        .buttonStyle(HoverRowStyle())
    }

    private var windowRow: some View {
        Button {
            appState.chooseAndRecord(mode: .window)
        } label: {
            CaptureRow(
                icon: "macwindow",
                title: "Record Window",
                subtitle: "Just one app window, even when it moves",
                shortcut: session.preferences.captureTarget == .window ? recordShortcut : nil,
                showsChevron: false
            )
        }
        .buttonStyle(HoverRowStyle())
    }

    private var selectedDisplayName: String {
        let id = CaptureGeometry.resolvedDisplayID(
            preferred: session.preferences.selectedDisplayID,
            available: session.availableDisplays.map(\.displayID),
            main: CGMainDisplayID()
        )
        return session.availableDisplays.first { $0.displayID == id }?.name ?? "Main display"
    }

    // MARK: - Devices

    private var devices: some View {
        HStack(spacing: DS.Spacing.xs) {
            DeviceChip(
                title: "Mic",
                onIcon: "mic.fill",
                offIcon: "mic.slash",
                isOn: $session.preferences.microphoneEnabled,
                warning: session.preferences.microphoneEnabled && !permissions.hasMicrophonePermission
                    ? "Microphone access needed" : nil
            ) {
                devicePicker(
                    "Microphone",
                    devices: session.availableMicrophones,
                    selection: $session.preferences.selectedMicrophoneID
                )
                if !permissions.hasMicrophonePermission {
                    Divider()
                    Button("Allow Microphone Access…") {
                        Task { await permissions.requestMicrophonePermission() }
                    }
                }
            }

            DeviceChip(
                title: "Camera",
                onIcon: "video.fill",
                offIcon: "video.slash",
                isOn: $session.preferences.cameraEnabled,
                warning: session.preferences.cameraEnabled && !permissions.hasCameraPermission
                    ? "Camera access needed" : nil
            ) {
                devicePicker(
                    "Camera",
                    devices: session.availableCameras,
                    selection: $session.preferences.selectedCameraID
                )
                Divider()
                Picker("Bubble Size", selection: $session.preferences.cameraSize) {
                    ForEach(CameraBubbleSize.allCases) { size in
                        Text(size.label).tag(size)
                    }
                }
                Picker("Bubble Position", selection: $session.preferences.cameraPosition) {
                    ForEach(CameraBubblePosition.allCases) { position in
                        Text(position.label).tag(position)
                    }
                }
                Picker("Background", selection: $session.preferences.cameraBackground) {
                    ForEach(CameraBackgroundMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                if !permissions.hasCameraPermission {
                    Divider()
                    Button("Allow Camera Access…") {
                        Task { await permissions.requestCameraPermission() }
                    }
                }
            }

            DeviceChip(
                title: "System",
                onIcon: "speaker.wave.2.fill",
                offIcon: "speaker.slash",
                isOn: $session.preferences.systemAudioEnabled,
                warning: nil,
                showsMenu: false
            ) {
                EmptyView()
            }
            .help("Record sound from other apps")
        }
    }

    @ViewBuilder
    private func devicePicker(_ title: String, devices: [MediaDeviceInfo], selection: Binding<String?>) -> some View {
        if devices.isEmpty {
            Text("No \(title.lowercased()) found")
        } else {
            Picker(title, selection: selection) {
                ForEach(devices) { device in
                    Text(device.name).tag(Optional(device.id))
                }
            }
            .pickerStyle(.inline)
        }
    }

    // MARK: - Setup

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("Finish setting up")
                .font(DS.Typeface.headline)
            Text("\(Brand.name) needs Screen Recording and Accessibility access to record and follow your clicks.")
                .font(DS.Typeface.footnote)
                .foregroundStyle(DS.Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Setup Guide") { appState.showOnboarding() }
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                .fill(DS.Palette.raisedSurface)
        )
        .padding(.horizontal, DS.Spacing.xs)
    }

    // MARK: - Recording states

    private func countdownStatus(_ remaining: Int) -> some View {
        VStack(spacing: DS.Spacing.sm) {
            Text("\(remaining)")
                .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText(countsDown: true))
            Text("Get ready…")
                .font(DS.Typeface.body)
                .foregroundStyle(DS.Palette.secondaryText)
            Button("Cancel") { session.cancelCountdown() }
                .buttonStyle(SecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.lg)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recording starts in \(remaining)")
    }

    private var recordingStatus: some View {
        VStack(spacing: DS.Spacing.sm) {
            Text(Self.format(session.elapsedTime))
                .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
            Text(session.isPaused ? "Paused" : (session.clickCount == 1 ? "1 click tracked" : "\(session.clickCount) clicks tracked"))
                .font(DS.Typeface.footnote)
                .foregroundStyle(DS.Palette.secondaryText)
            HStack(spacing: DS.Spacing.xs) {
                Button {
                    session.togglePause()
                } label: {
                    Label(session.isPaused ? "Resume" : "Pause", systemImage: session.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(SecondaryButtonStyle())
                Button {
                    Task { await session.stop() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(PrimaryButtonStyle(tint: DS.Palette.recording))
                if let stop = settings.settings.hotkeys[.stop] {
                    ShortcutBadge(text: stop.displayString)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.lg)
    }

    private var processingStatus: some View {
        HStack(spacing: DS.Spacing.sm) {
            ProgressView()
                .controlSize(.small)
            Text("Saving your recording…")
                .font(DS.Typeface.body)
                .foregroundStyle(DS.Palette.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.lg)
    }

    static func format(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Pieces

/// The app's mark: the accent-coloured record glyph on a rounded square.
struct BrandMark: View {
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [DS.Palette.accent, DS.Palette.accent.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "record.circle")
                .font(.system(size: size * 0.55, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A red dot that gently pulses (steady with Reduce Motion).
struct RecordingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDimmed = false

    var body: some View {
        Circle()
            .fill(DS.Palette.recording)
            .frame(width: 8, height: 8)
            .opacity(isDimmed ? 0.35 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    isDimmed = true
                }
            }
            .accessibilityLabel("Recording")
    }
}

private struct CaptureRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let shortcut: String?
    let showsChevron: Bool

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DS.Palette.accent)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                        .fill(DS.Palette.accent.opacity(0.12))
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(DS.Typeface.headline)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(DS.Typeface.caption)
                    .foregroundStyle(DS.Palette.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: DS.Spacing.xs)
            if let shortcut {
                ShortcutBadge(text: shortcut)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DS.Palette.tertiaryText)
            }
        }
        .contentShape(Rectangle())
    }
}

/// A toggle chip for an input device, with a menu for choosing which one.
private struct DeviceChip<MenuContent: View>: View {
    let title: String
    let onIcon: String
    let offIcon: String
    @Binding var isOn: Bool
    let warning: String?
    var showsMenu = true
    @ViewBuilder var menuContent: () -> MenuContent

    var body: some View {
        HStack(spacing: 0) {
            Button {
                isOn.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isOn ? onIcon : offIcon)
                        .frame(width: 14)
                    Text(title)
                        .lineLimit(1)
                }
                .font(DS.Typeface.footnote.weight(.medium))
                .padding(.leading, 10)
                .padding(.trailing, showsMenu ? 4 : 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isOn ? "On" : "Off")
            .accessibilityHint("Turns \(title.lowercased()) recording on or off")

            if showsMenu {
                Menu {
                    menuContent()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.trailing, 8)
                .accessibilityLabel("\(title) options")
            }
        }
        .foregroundStyle(isOn ? DS.Palette.accent : Color.primary)
        .background(
            Capsule().fill(isOn ? DS.Palette.accent.opacity(0.14) : DS.Palette.raisedSurface)
        )
        .overlay(alignment: .topTrailing) {
            if warning != nil {
                Circle()
                    .fill(DS.Palette.warning)
                    .frame(width: 7, height: 7)
                    .offset(x: -2, y: 2)
            }
        }
        .help(warning ?? "")
    }
}

private struct NoticeBanner: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DS.Palette.warning)
        }
        .font(DS.Typeface.footnote)
        .padding(DS.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                .fill(DS.Palette.warning.opacity(0.12))
        )
    }
}
