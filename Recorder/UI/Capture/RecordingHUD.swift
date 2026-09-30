import AppKit
import Combine
import SwiftUI

/// Floating controls while recording (timer, pause, restart, discard, stop) and, for an
/// area recording, a dashed border just outside the area. Both belong to this app, so
/// display and area recordings leave them out, and window recordings never see them.
@MainActor
final class RecordingOverlays {
    private let session: RecordingSession
    private let settings: SettingsStore
    private var hudPanel: NSPanel?
    private var borderPanel: NSPanel?
    private var cancellables = Set<AnyCancellable>()

    init(session: RecordingSession, settings: SettingsStore) {
        self.session = session
        self.settings = settings
        session.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.update(for: state)
            }
            .store(in: &cancellables)
    }

    private func update(for state: RecordingSession.State) {
        switch state {
        case .recording:
            if settings.settings.showRecordingHUD, hudPanel == nil {
                showHUD()
            }
            if borderPanel == nil, let area = session.recordingAreaFrame {
                showBorder(around: area)
            }
        default:
            hudPanel?.orderOut(nil)
            hudPanel = nil
            borderPanel?.orderOut(nil)
            borderPanel = nil
        }
    }

    private func showHUD() {
        let hosting = NSHostingView(rootView: RecordingHUDView(session: session, settings: settings))
        let size = hosting.fittingSize
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = hosting
        panel.setFrameOrigin(hudOrigin(size: size))
        panel.orderFrontRegardless()
        hudPanel = panel
    }

    /// Below the recorded area if there's room, otherwise near the bottom of the screen.
    private func hudOrigin(size: CGSize) -> CGPoint {
        let screen = session.recordingScreen ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        if let area = session.recordingAreaFrame, area.minY - size.height - 16 > visible.minY {
            return CGPoint(
                x: min(max(area.midX - size.width / 2, visible.minX + 12), visible.maxX - size.width - 12),
                y: area.minY - size.height - 16
            )
        }
        return CGPoint(x: visible.midX - size.width / 2, y: visible.minY + 28)
    }

    private func showBorder(around area: CGRect) {
        let inset: CGFloat = -4
        let frame = area.insetBy(dx: inset, dy: inset)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: AreaBorderView())
        panel.orderFrontRegardless()
        borderPanel = panel
    }
}

private struct AreaBorderView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            .foregroundStyle(DS.Palette.recording.opacity(0.85))
            .accessibilityHidden(true)
    }
}

struct RecordingHUDView: View {
    @ObservedObject var session: RecordingSession
    @ObservedObject var settings: SettingsStore
    @State private var confirmingDiscard = false

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 7) {
                if session.isPaused {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DS.Palette.warning)
                } else {
                    RecordingDot()
                }
                Text(MenuBarView.format(session.elapsedTime))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(minWidth: 38, alignment: .leading)
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(session.isPaused ? "Paused at \(MenuBarView.format(session.elapsedTime))" : "Recording, \(MenuBarView.format(session.elapsedTime))")

            hudButton(
                session.isPaused ? "Resume" : "Pause",
                icon: session.isPaused ? "play.fill" : "pause.fill",
                shortcut: settings.settings.hotkeys[.pauseResume]
            ) {
                session.togglePause()
            }

            hudButton("Restart", icon: "arrow.counterclockwise", shortcut: settings.settings.hotkeys[.restart]) {
                Task { await session.restart() }
            }

            if confirmingDiscard {
                Button {
                    Task { await session.discard() }
                } label: {
                    Text("Discard?")
                        .font(DS.Typeface.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(Capsule().fill(DS.Palette.recording))
                }
                .buttonStyle(.plain)
                .help("Click again to delete this take")
                .task {
                    // Back to the plain button if not confirmed soon.
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    confirmingDiscard = false
                }
            } else {
                hudButton("Discard", icon: "trash", shortcut: nil) {
                    confirmingDiscard = true
                }
            }

            Button {
                Task { await session.stop() }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(DS.Palette.recording)
                    )
            }
            .buttonStyle(.plain)
            .help(helpText("Stop", settings.settings.hotkeys[.stop]))
            .accessibilityLabel("Stop recording")
            .padding(.trailing, 4)
        }
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.82))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.14))
        )
        .environment(\.colorScheme, .dark)
        .fixedSize()
        .padding(6)
    }

    private func hudButton(_ title: String, icon: String, shortcut: KeyCombo?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
        .buttonStyle(IconButtonStyle(size: 26))
        .help(helpText(title, shortcut))
        .accessibilityLabel(title)
    }

    private func helpText(_ title: String, _ shortcut: KeyCombo?) -> String {
        shortcut.map { "\(title) (\($0.displayString))" } ?? title
    }
}
