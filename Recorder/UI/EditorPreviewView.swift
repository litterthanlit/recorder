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
                ZStack {
                    CompositorPreviewView(editor: editor)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    if editor.isManualZoomMode {
                        manualSelectionOverlay(contentFrame: contentFrame(in: geometry.size))
                    }
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 360)

            playbackControls
        }
    }

    /// Where the compositor draws the video inside the preview, in view coordinates.
    private func contentFrame(in size: CGSize) -> CGRect {
        let style = editor.editSettings.exportStyle
        let padding = style.backgroundEnabled ? size.width * style.paddingFraction : 0
        let aspect = CGFloat(editor.project.metadata.width) / CGFloat(max(editor.project.metadata.height, 1))
        return ZoomKeyframeEditor.fittedContentFrame(contentAspect: aspect, in: size, padding: padding)
    }

    @ViewBuilder
    private func manualSelectionOverlay(contentFrame: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
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
                            let selection = pixelRect(from: dragStart ?? value.startLocation, to: value.location)
                            dragStart = nil
                            dragCurrent = nil
                            guard selection.width > 8, selection.height > 8,
                                  let sourceRect = ZoomKeyframeEditor.sourceRect(
                                      forSelection: selection,
                                      contentFrame: contentFrame,
                                      // The preview may already be zoomed; map through what is on screen.
                                      visibleCrop: editor.interpolator.cropRect(at: editor.playheadTime)
                                  )
                            else { return }
                            editor.addManualZoom(from: sourceRect)
                        }
                )

            Rectangle()
                .strokeBorder(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .frame(width: contentFrame.width, height: contentFrame.height)
                .offset(x: contentFrame.minX, y: contentFrame.minY)
                .allowsHitTesting(false)

            if let selectionRect = currentSelectionRect()?.intersection(contentFrame), !selectionRect.isNull {
                Rectangle()
                    .strokeBorder(Color.orange, lineWidth: 2)
                    .background(Color.orange.opacity(0.15))
                    .frame(width: selectionRect.width, height: selectionRect.height)
                    .offset(x: selectionRect.minX, y: selectionRect.minY)
                    .allowsHitTesting(false)
            }
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 12) {
            Button {
                editor.togglePlayback()
            } label: {
                Image(systemName: editor.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.bordered)

            Slider(
                value: Binding(
                    get: { editor.playheadTime },
                    set: { editor.seek(to: $0) }
                ),
                in: editor.trimStart...max(editor.trimEnd, editor.trimStart + 0.01)
            )

            Text(formatTime(editor.playheadTime))
                .font(.caption.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func currentSelectionRect() -> CGRect? {
        guard let dragStart, let dragCurrent else { return nil }
        return pixelRect(from: dragStart, to: dragCurrent)
    }

    private func pixelRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let totalSeconds = Int(time.rounded(.down))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%01d:%02d", minutes, seconds)
    }
}
