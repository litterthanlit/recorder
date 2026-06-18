import AVKit
import SwiftUI

struct EditorPreviewView: View {
    @ObservedObject var editor: ProjectEditor

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Preview")
                    .font(.headline)
                Spacer()
                if editor.isManualZoomMode {
                    Text("Drag to select zoom area")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            GeometryReader { geometry in
                let crop = editor.interpolator.cropRect(at: editor.playheadTime)
                let scale = 1 / max(crop.width, 0.001)
                let anchor = UnitPoint(
                    x: crop.x + crop.width / 2,
                    y: crop.y + crop.height / 2
                )

                ZStack {
                    VideoPlayer(player: editor.player)
                        .scaleEffect(scale, anchor: anchor)
                        .clipped()

                    if editor.isManualZoomMode {
                        manualSelectionOverlay(in: geometry.size)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .frame(height: 320)
            .background(Color.black.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            playbackControls
        }
    }

    @ViewBuilder
    private func manualSelectionOverlay(in size: CGSize) -> some View {
        let selectionRect = currentSelectionRect(in: size)

        ZStack {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            if dragStart == nil {
                                dragStart = value.startLocation
                            }
                            dragCurrent = value.location
                        }
                        .onEnded { value in
                            let start = dragStart ?? value.startLocation
                            let end = value.location
                            let rect = pixelRect(from: start, to: end, in: size)
                            if rect.width > 8, rect.height > 8 {
                                editor.addManualZoom(from: normalizedRect(from: rect, in: size))
                            }
                            dragStart = nil
                            dragCurrent = nil
                        }
                )

            if let selectionRect {
                Rectangle()
                    .strokeBorder(Color.orange, lineWidth: 2)
                    .background(Color.orange.opacity(0.15))
                    .frame(width: selectionRect.width, height: selectionRect.height)
                    .position(x: selectionRect.midX, y: selectionRect.midY)
            }
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 12) {
            Button {
                editor.togglePlayback()
            } label: {
                Image(systemName: editor.player.rate > 0 ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.bordered)

            Slider(
                value: Binding(
                    get: { editor.playheadTime },
                    set: { editor.seek(to: $0) }
                ),
                in: 0...max(editor.duration, 0.01)
            )

            Text(formatTime(editor.playheadTime))
                .font(.caption.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func currentSelectionRect(in size: CGSize) -> CGRect? {
        guard let dragStart, let dragCurrent else { return nil }
        return pixelRect(from: dragStart, to: dragCurrent, in: size)
    }

    private func pixelRect(from start: CGPoint, to end: CGPoint, in size: CGSize) -> CGRect {
        let minX = min(start.x, end.x)
        let minY = min(start.y, end.y)
        let width = abs(end.x - start.x)
        let height = abs(end.y - start.y)
        return CGRect(x: minX, y: minY, width: width, height: height)
    }

    private func normalizedRect(from rect: CGRect, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGRect(
            x: rect.minX / size.width,
            y: rect.minY / size.height,
            width: rect.width / size.width,
            height: rect.height / size.height
        )
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let totalSeconds = Int(time.rounded(.down))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%01d:%02d", minutes, seconds)
    }
}
