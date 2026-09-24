import AppKit
import SwiftUI

@MainActor
final class CountdownOverlay {
    private var panel: NSPanel?
    private var countdownTask: Task<Bool, Never>?

    /// Called on each second tick with the remaining value.
    var onTick: ((Int) -> Void)?

    /// Runs a visible countdown on `screen` (the main screen if `nil`). Returns `true` if
    /// it finished, `false` if cancelled.
    @discardableResult
    func run(seconds: Int, on screen: NSScreen? = nil) async -> Bool {
        cancel()
        guard seconds > 0 else { return true }

        let panel = makePanel(on: screen ?? NSScreen.main ?? NSScreen.screens[0])
        self.panel = panel
        panel.orderFrontRegardless()

        let task = Task<Bool, Never> { @MainActor in
            for remaining in stride(from: seconds, through: 1, by: -1) {
                if Task.isCancelled { return false }
                self.update(panel: panel, value: remaining)
                self.onTick?(remaining)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return false }
            }
            self.dismiss()
            return true
        }

        countdownTask = task
        let completed = await task.value
        if countdownTask == task {
            countdownTask = nil
        }
        if !completed {
            dismiss()
        }
        return completed
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

    private func makePanel(on screen: NSScreen) -> NSPanel {
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
