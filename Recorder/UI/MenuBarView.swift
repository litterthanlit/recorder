import SwiftUI

struct MenuBarView: View {
    @ObservedObject var session: RecordingSession
    @ObservedObject var permissions: PermissionsManager
    @ObservedObject var library: ProjectLibrary
    var onOpenEditor: (RecorderProject) -> Void
    var onOpenProject: (ProjectSummary) -> Void
    var onTrashProject: (ProjectSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if !permissions.hasRequiredPermissions {
                permissionsSection
            } else {
                recordingOptionsSection
                statusSection
                controlsSection

                // Hidden mid-take so the panel stays focused on the recording.
                if !session.isBusy {
                    Divider()
                    RecentProjectsView(
                        library: library,
                        onOpen: onOpenProject,
                        onTrash: onTrashProject
                    )
                }

                hotkeyHints
            }
        }
        .padding(16)
        .frame(width: 360)
        .onAppear {
            permissions.refresh()
            session.refreshMediaDevices()
            session.refreshDisplays()
            library.refresh()
            Task { await session.refreshWindows() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recorder")
                .font(.title3.weight(.semibold))
            Text("Spring zoom, click FX, launch-ready export")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var recordingOptionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recording")
                .font(.subheadline.weight(.medium))

            Picker("Capture", selection: $session.preferences.captureTarget) {
                ForEach(CaptureTargetKind.allCases) { target in
                    Text(target.label).tag(target)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: session.preferences.captureTarget) { _ in
                Task { await session.refreshWindows() }
            }

            if session.preferences.captureTarget == .display, session.availableDisplays.count > 1 {
                Picker("Display", selection: Binding(
                    // An unplugged choice shows (and records) the main display.
                    get: {
                        CaptureGeometry.resolvedDisplayID(
                            preferred: session.preferences.selectedDisplayID,
                            available: session.availableDisplays.map(\.displayID),
                            main: CGMainDisplayID()
                        ) ?? CGMainDisplayID()
                    },
                    set: { session.preferences.selectedDisplayID = $0 }
                )) {
                    ForEach(session.availableDisplays) { display in
                        Text(display.name).tag(display.displayID)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("Display to record")
            }

            if session.preferences.captureTarget == .window {
                Picker("Window", selection: Binding(
                    get: { session.preferences.selectedWindowID ?? 0 },
                    set: { session.preferences.selectedWindowID = $0 == 0 ? nil : $0 }
                )) {
                    if session.availableWindows.isEmpty {
                        Text("No windows available").tag(UInt32(0))
                    } else {
                        ForEach(session.availableWindows) { window in
                            Text(window.displayName).tag(window.windowID)
                        }
                    }
                }
                .labelsHidden()

                Button("Refresh Windows") {
                    Task { await session.refreshWindows() }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            Stepper(
                "Countdown: \(session.preferences.countdownSeconds)s",
                value: $session.preferences.countdownSeconds,
                in: 0...10
            )

            Toggle("Hide menu bar & dock", isOn: $session.preferences.hideChromeDuringRecording)
            Toggle("Smooth cursor on export", isOn: $session.preferences.cursorSmoothingEnabled)

            Divider()

            Toggle("Microphone", isOn: $session.preferences.microphoneEnabled)
            if session.preferences.microphoneEnabled {
                if !permissions.hasMicrophonePermission {
                    permissionHint(
                        title: "Mic permission needed",
                        action: { Task { await permissions.requestMicrophonePermission() } },
                        settings: { permissions.openSystemSettings(for: .microphone) }
                    )
                }

                Picker("Mic", selection: Binding(
                    get: { session.preferences.selectedMicrophoneID ?? "" },
                    set: { session.preferences.selectedMicrophoneID = $0.isEmpty ? nil : $0 }
                )) {
                    if session.availableMicrophones.isEmpty {
                        Text("No microphones").tag("")
                    } else {
                        ForEach(session.availableMicrophones) { mic in
                            Text(mic.name).tag(mic.id)
                        }
                    }
                }
            }

            Toggle("Camera", isOn: $session.preferences.cameraEnabled)
            if session.preferences.cameraEnabled {
                if !permissions.hasCameraPermission {
                    permissionHint(
                        title: "Camera permission needed",
                        action: { Task { await permissions.requestCameraPermission() } },
                        settings: { permissions.openSystemSettings(for: .camera) }
                    )
                }

                Picker("Camera", selection: Binding(
                    get: { session.preferences.selectedCameraID ?? "" },
                    set: { session.preferences.selectedCameraID = $0.isEmpty ? nil : $0 }
                )) {
                    if session.availableCameras.isEmpty {
                        Text("No cameras").tag("")
                    } else {
                        ForEach(session.availableCameras) { camera in
                            Text(camera.name).tag(camera.id)
                        }
                    }
                }

                Picker("Position", selection: $session.preferences.cameraPosition) {
                    ForEach(CameraBubblePosition.allCases) { position in
                        Text(position.label).tag(position)
                    }
                }

                Picker("Background", selection: $session.preferences.cameraBackground) {
                    ForEach(CameraBackgroundMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            }
        }
    }

    private func permissionHint(
        title: String,
        action: @escaping () -> Void,
        settings: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(.orange)
            Spacer()
            Button("Grant", action: action)
                .buttonStyle(.bordered)
                .controlSize(.mini)
            Button("Settings", action: settings)
                .buttonStyle(.borderless)
                .font(.caption)
        }
    }

    private var hotkeyHints: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Hotkeys")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text("⌘⇧R — Start   ·   ⌘⇧. — Stop / Cancel")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Permissions required")
                .font(.subheadline.weight(.medium))

            permissionRow(
                title: "Screen Recording",
                granted: permissions.hasScreenRecordingPermission,
                action: { permissions.requestScreenRecordingPermission() },
                settings: { permissions.openSystemSettings(for: .screenRecording) }
            )

            permissionRow(
                title: "Accessibility",
                granted: permissions.hasAccessibilityPermission,
                action: { permissions.requestAccessibilityPermission() },
                settings: { permissions.openSystemSettings(for: .accessibility) }
            )

            Button("Refresh Permissions") {
                permissions.refresh()
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    private func permissionRow(
        title: String,
        granted: Bool,
        action: @escaping () -> Void,
        settings: @escaping () -> Void
    ) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? .green : .orange)

            Text(title)
                .font(.subheadline)

            Spacer()

            if !granted {
                Button("Grant", action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                Button("Settings", action: settings)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if let notice = session.notice {
            Label(notice, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }

        switch session.state {
        case .idle:
            Text("Ready to record your screen.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

        case let .countdown(remaining):
            Label("Starting in \(remaining)…", systemImage: "timer")
                .font(.subheadline)
                .foregroundStyle(.orange)

        case .recording:
            VStack(alignment: .leading, spacing: 6) {
                Label("Recording", systemImage: "record.circle.fill")
                    .foregroundStyle(.red)
                Text("Duration: \(formattedTime(session.elapsedTime))")
                    .font(.caption.monospacedDigit())
                Text("Clicks tracked: \(session.clickCount)")
                    .font(.caption)
            }

        case .processing:
            Label("Processing clicks…", systemImage: "sparkles")
                .font(.subheadline)

        case let .editing(project):
            VStack(alignment: .leading, spacing: 8) {
                Label("Ready to edit", systemImage: "slider.horizontal.3")
                    .foregroundStyle(.blue)
                Text("\(project.keyframes.count) zoom keyframes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .exporting:
            VStack(alignment: .leading, spacing: 8) {
                Label("Exporting with auto zoom…", systemImage: "film")
                    .font(.subheadline)
                ProgressView(value: session.exportProgress)
            }

        case let .finished(project):
            VStack(alignment: .leading, spacing: 10) {
                Label("Export complete", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("\(project.keyframes.count) zoom keyframes applied")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                PreviewView(url: project.exportURL)
            }

        case let .failed(message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    @ViewBuilder
    private var controlsSection: some View {
        switch session.state {
        case .idle, .failed:
            Button {
                Task { await session.start() }
            } label: {
                Label("Record", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)

        case .countdown:
            Button {
                session.cancelCountdown()
            } label: {
                Label("Cancel", systemImage: "xmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

        case .recording:
            Button {
                Task { await session.stop() }
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

        case .processing, .exporting:
            EmptyView()

        case let .editing(project):
            HStack {
                Button {
                    onOpenEditor(project)
                } label: {
                    Label("Open Editor", systemImage: "slider.horizontal.3")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                newRecordingButton
            }

        case let .finished(project):
            HStack {
                Button {
                    onOpenEditor(project)
                } label: {
                    Label("Edit", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)

                Button {
                    session.revealExportInFinder()
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .buttonStyle(.bordered)

                newRecordingButton
            }
        }
    }

    /// Leaves the current take on disk (it stays in ~/Movies/Recorder) and gets ready for
    /// the next one. ⌘⇧R does the same and starts recording straight away.
    private var newRecordingButton: some View {
        Button {
            session.reset()
        } label: {
            Label("New Recording", systemImage: "record.circle")
        }
        .buttonStyle(.bordered)
        .help("Start over with a new take (⌘⇧R)")
    }

    private func formattedTime(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(interval.rounded(.down))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
