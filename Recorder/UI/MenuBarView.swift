import SwiftUI

struct MenuBarView: View {
    @ObservedObject var session: RecordingSession
    @ObservedObject var permissions: PermissionsManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if !permissions.hasRequiredPermissions {
                permissionsSection
            } else {
                statusSection
                controlsSection
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear {
            permissions.refresh()
        }
        .onChange(of: session.state) { newValue in
            if case let .editing(project) = newValue {
                openWindow(id: "editor", value: project.metadata.id)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recorder")
                .font(.title3.weight(.semibold))
            Text("Auto zoom + timeline editor")
                .font(.caption)
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
        switch session.state {
        case .idle:
            Text("Ready to record your screen.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

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

        case .editing:
            Button {
                if case let .editing(project) = session.state {
                    openWindow(id: "editor", value: project.metadata.id)
                }
            } label: {
                Label("Open Editor", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

        case .finished:
            HStack {
                Button {
                    session.revealExportInFinder()
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .buttonStyle(.bordered)

                Button("New Recording") {
                    session.reset()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func formattedTime(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(interval.rounded(.down))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
