import AppKit
import Combine
import SwiftUI

/// The menu bar item: Trace's mark. Idle, a click opens the panel; while recording the
/// mark's top-right corner turns red beside the elapsed time, and a click stops the take
/// (a right click always opens the menu).
@MainActor
final class StatusItemController: NSObject {
    private let appState: AppState
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()

    init(appState: AppState) {
        self.appState = appState
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let hosting = NSHostingController(rootView: MenuBarView(appState: appState))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }

        appState.showPanelHandler = { [weak self] in self?.showPanel() }
        appState.dismissPanelHandler = { [weak self] in self?.closePanel() }

        appState.session.$state
            .combineLatest(
                appState.session.$elapsedTime.map { Int($0) }.removeDuplicates(),
                appState.session.$isPaused
            )
            .sink { [weak self] state, elapsed, isPaused in
                self?.updateButton(state: state, elapsedSeconds: elapsed, isPaused: isPaused)
            }
            .store(in: &cancellables)
    }

    // MARK: - Panel

    func showPanel() {
        guard let button = statusItem.button, !popover.isShown else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func closePanel() {
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
            return
        }
        switch appState.session.state {
        case .recording:
            Task { await appState.session.stop() }
        case .countdown:
            appState.session.cancelCountdown()
        default:
            if popover.isShown {
                closePanel()
            } else {
                showPanel()
            }
        }
    }

    private func showMenu() {
        closePanel()
        let menu = NSMenu()
        let session = appState.session
        switch session.state {
        case .recording:
            menu.addItem(item("Stop Recording", #selector(stopRecording)))
            menu.addItem(item(session.isPaused ? "Resume Recording" : "Pause Recording", #selector(togglePause)))
            menu.addItem(item("Restart Recording", #selector(restartRecording)))
        case .countdown:
            menu.addItem(item("Cancel Recording", #selector(stopRecording)))
        default:
            menu.addItem(item("New Recording", #selector(newRecording)))
        }
        menu.addItem(.separator())
        menu.addItem(item("Library…", #selector(openLibrary)))
        menu.addItem(item("Settings…", #selector(openSettings)))
        menu.addItem(.separator())
        menu.addItem(item("Quit \(Brand.name)", #selector(quit)))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func newRecording() {
        appState.chooseAndRecord()
    }

    @objc private func stopRecording() {
        switch appState.session.state {
        case .recording:
            Task { await appState.session.stop() }
        case .countdown:
            appState.session.cancelCountdown()
        default:
            break
        }
    }

    @objc private func togglePause() {
        appState.session.togglePause()
    }

    @objc private func restartRecording() {
        Task { await appState.session.restart() }
    }

    @objc private func openLibrary() {
        appState.showLibrary()
    }

    @objc private func openSettings() {
        appState.showSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Button

    private func updateButton(state: RecordingSession.State, elapsedSeconds: Int, isPaused: Bool) {
        guard let button = statusItem.button else { return }
        switch state {
        case .recording where isPaused:
            button.image = Self.symbol("pause.circle.fill")
            button.attributedTitle = Self.timerTitle(" " + Self.format(elapsedSeconds))
            button.setAccessibilityLabel("Recording paused at \(Self.format(elapsedSeconds)). Click to stop.")
        case .recording:
            button.image = Self.recordingMark
            button.attributedTitle = Self.timerTitle(" " + Self.format(elapsedSeconds))
            button.setAccessibilityLabel("Recording, \(Self.format(elapsedSeconds)). Click to stop.")
        case let .countdown(remaining):
            button.image = Self.symbol("timer")
            button.attributedTitle = Self.timerTitle(" \(remaining)")
            button.setAccessibilityLabel("Recording starts in \(remaining). Click to cancel.")
        case .processing:
            button.image = Self.symbol("ellipsis.circle")
            button.title = ""
            button.setAccessibilityLabel("\(Brand.name) is saving the recording")
        case .idle, .editing, .finished, .failed:
            button.image = Self.idleMark
            button.title = ""
            button.setAccessibilityLabel(Brand.name)
        }
    }

    private static func format(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: Brand.name)
        image?.isTemplate = true
        return image
    }

    private static func timerTitle(_ text: String) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)]
        )
    }

    /// The mark as a template image, so the menu bar tints it.
    private static let idleMark = markImage(recording: false)

    /// The mark with its REC corner red. Not a template image, so the corner stays red; the
    /// other corners are drawn in the label colour of the menu bar's appearance.
    private static let recordingMark = markImage(recording: true)

    private static func markImage(recording: Bool) -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            let mark = FrameMark.glyph
            for corner in FrameMark.Corner.allCases {
                let points = mark.polyline(corner, side: side)
                let path = NSBezierPath()
                path.move(to: points[0])
                for point in points.dropFirst() {
                    path.line(to: point)
                }
                path.lineWidth = side * mark.lineWidth
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                let color: NSColor
                if recording {
                    color = corner == .topRight ? .systemRed : .labelColor
                } else {
                    color = .black
                }
                color.setStroke()
                path.stroke()
            }
            return true
        }
        image.isTemplate = !recording
        image.accessibilityDescription = Brand.name
        return image
    }
}
