import AppKit
import SwiftUI

@MainActor
final class CountdownOverlay {
    private var panel: NSPanel?
    private var countdownTask: Task<Void, Never>?

    func run(seconds: Int) async {
        cancel()
        guard seconds > 0 else { return }

        let panel = makePanel()
        self.panel = panel
        panel.orderFrontRegardless()

        for remaining in stride(from: seconds, through: 1, by: -1) {
            update(panel: panel, value: remaining)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { break }
        }

        dismiss()
    }

    func cancel() {
        countdownTask?.cancel()
        countdownTask = nil
        dismiss()
    }

    private func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func makePanel() -> NSPanel {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: CountdownOverlayView(value: 3))
        return panel
    }

    private func update(panel: NSPanel, value: Int) {
        if let hosting = panel.contentView as? NSHostingView<CountdownOverlayView> {
            hosting.rootView = CountdownOverlayView(value: value)
        }
    }
}

private struct CountdownOverlayView: View {
    let value: Int

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()

            Text("\(value)")
                .font(.system(size: 120, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(radius: 12)
        }
    }
}
