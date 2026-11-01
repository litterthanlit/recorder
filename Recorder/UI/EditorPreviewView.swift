import SwiftUI

/// The editor's canvas: the video at its export shape on a quiet well, with the tools
/// for aiming zooms and placing text and blur on top.
struct EditorPreviewView: View {
    @ObservedObject var editor: ProjectEditor

    private var aspect: CGFloat {
        let size = editor.exportOutputSize
        return size.width / max(size.height, 1)
    }

    var body: some View {
        GeometryReader { geometry in
            let canvas = Self.fittedSize(aspect: aspect, in: geometry.size, margin: DS.Spacing.lg)
            ZStack {
                CompositorPreviewView(editor: editor)
                    .frame(width: canvas.width, height: canvas.height)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .shadow(color: .black.opacity(0.28), radius: 18, y: 6)
                    .accessibilityLabel("Preview")
                CanvasOverlay(editor: editor, playback: editor.playback, canvasSize: canvas)
                    .frame(width: canvas.width, height: canvas.height)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(DS.Palette.canvas)
        .overlay(alignment: .top) {
            modeBanner
                .padding(.top, DS.Spacing.xs)
        }
    }

    @ViewBuilder
    private var modeBanner: some View {
        if editor.isCropMode {
            CanvasBanner(text: "Drag over the part to keep, like your app's window", actionTitle: "Cancel") {
                editor.isCropMode = false
            }
        } else if editor.isManualZoomMode {
            CanvasBanner(text: "Drag over the area to zoom into", actionTitle: "Cancel") {
                editor.isManualZoomMode = false
            }
        } else if editor.isEditingZoomFocus {
            CanvasBanner(text: "Drag the frame to aim the zoom, or a corner to resize it", actionTitle: "Done") {
                editor.isEditingZoomFocus = false
            }
        }
    }

    /// The largest size of `aspect` that fits `size` with `margin` all round.
    static func fittedSize(aspect: CGFloat, in size: CGSize, margin: CGFloat) -> CGSize {
        let available = CGSize(width: max(size.width - margin * 2, 10), height: max(size.height - margin * 2, 10))
        let safeAspect = aspect > 0 ? aspect : 16.0 / 9.0
        let width = min(available.width, available.height * safeAspect)
        return CGSize(width: width, height: width / safeAspect)
    }
}

/// A floating hint over the canvas with one action (Cancel, Done).
private struct CanvasBanner: View {
    let text: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            Text(text)
                .font(DS.Typeface.footnote.weight(.medium))
            Button(actionTitle, action: action)
                .buttonStyle(PrimaryButtonStyle())
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.leading, DS.Spacing.sm)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }
}
