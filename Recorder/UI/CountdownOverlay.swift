import AppKit
import SwiftUI

@MainActor
final class CountdownOverlay {
    private var panel: NSPanel?
    private var countdownTask: Task<Bool, Never>?
    private var highlight: CGRect?

    /// Called on each second tick with the remaining value.
    var onTick: ((Int) -> Void)?

    /// Runs a visible countdown on `screen` (the main screen if `nil`). Returns `true` if
    /// it finished, `false` if cancelled.
    /// - Parameter highlight: an area to keep undimmed and centre the count in, in the
    ///   screen's points with a top-left origin.
    @discardableResult
    func run(seconds: Int, on screen: NSScreen? = nil, highlight: CGRect? = nil) async -> Bool {
        cancel()
        guard seconds > 0 else { return true }

        self.highlight = highlight
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
        panel.contentView = NSHostingView(rootView: CountdownOverlayView(value: 3, highlight: highlight))
        return panel
    }

    private func update(panel: NSPanel, value: Int) {
        if let hosting = panel.contentView as? NSHostingView<CountdownOverlayView> {
            hosting.rootView = CountdownOverlayView(value: value, highlight: highlight)
        }
    }
}

private struct CountdownOverlayView: View {
    let value: Int
    let highlight: CGRect?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let full = CGRect(origin: .zero, size: proxy.size)
            let focus = highlight ?? full
            ZStack {
                Path { path in
                    path.addRect(full)
                    if let highlight {
                        path.addRect(highlight)
                    }
                }
                .fill(Color.black.opacity(0.4), style: FillStyle(eoFill: true))

                VStack(spacing: DS.Spacing.sm) {
                    Text("\(value)")
                        .font(.system(size: 88, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .contentTransition(.numericText(countsDown: true))
                        .frame(width: 168, height: 168)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                    Text("Recording starts…")
                        .font(DS.Typeface.title)
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(color: .black.opacity(0.5), radius: 6)
                }
                .position(x: focus.midX, y: focus.midY)
                .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: value)
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recording starts in \(value)")
    }
}
