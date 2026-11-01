import AppKit
import SwiftUI

/// The inspector's crop row: what the video shows, with buttons to draw a crop over the
/// recording, follow an app's window, or go back to all of it.
struct CropControls: View {
    @ObservedObject var editor: ProjectEditor

    private var isCropped: Bool {
        editor.editSettings.sourceCrop != nil
    }

    private var summary: String {
        guard isCropped else { return "Shows the whole recording" }
        let size = editor.contentSize
        // String(_:) keeps the digits ungrouped: "1920", not "1,920".
        let shown = "Shows \(String(Int(size.width.rounded()))) × \(String(Int(size.height.rounded()))) pixels of the recording"
        guard let path = editor.editSettings.cropPath else { return shown }
        return "\(shown), following \(path.app ?? "the window") as it moves"
    }

    /// Apps whose window showed in the recording, longest in front first.
    private var windowApps: [String] {
        let focus = editor.project.inputs.appFocus
        return AppFocusTimeline.timeByApp(focus, duration: editor.duration)
            .map { $0.appName }
            .filter { app in focus.contains { $0.isApp(app) && $0.windowRect != nil } }
    }

    var body: some View {
        InspectorLabeled("Crop") {
            HStack(spacing: DS.Spacing.xs) {
                Button(isCropped ? "Change Crop…" : "Crop…", action: startCropping)
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityHint("Draw the part of the recording to keep, like your app's window")
                if isCropped {
                    Button("Show All") {
                        editor.setSourceCrop(nil)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityLabel("Show the whole recording")
                }
            }
            followMenu
            InspectorHint(summary)
        }
    }

    @ViewBuilder
    private var followMenu: some View {
        let apps = windowApps
        if !apps.isEmpty {
            Menu {
                ForEach(apps, id: \.self) { app in
                    Button(app) {
                        _ = editor.cropToWindow(of: app)
                    }
                }
            } label: {
                Label("Follow a Window", systemImage: "macwindow")
            }
            .fixedSize()
            .accessibilityHint("Crop to an app's window and follow it as it moves")
        }
    }

    private func startCropping() {
        editor.pausePlayback()
        editor.isManualZoomMode = false
        editor.isEditingZoomFocus = false
        editor.isCropMode = true
    }
}

/// Crop mode on the canvas: the whole recording, with the part kept outlined; drag over
/// the part to keep.
struct CropSelection: View {
    let editor: ProjectEditor
    /// Where the whole recording is drawn (view points, top-left origin).
    let contentFrame: CGRect

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?

    /// Smaller drags are taken as a slip, not a crop.
    private static let minimumSize: CGFloat = 24

    /// The crop now in place (where it is at the playhead, when it follows a window), in
    /// view points.
    private var currentFrame: CGRect? {
        guard editor.editSettings.sourceCrop != nil else { return nil }
        let crop = editor.editSettings.cropBase(at: editor.playheadSourceTime)
        return ZoomKeyframeEditor.viewRect(forSource: crop, contentFrame: contentFrame, visibleCrop: .fullFrame)
    }

    /// The crop being drawn, in view points.
    private var drawnFrame: CGRect? {
        guard let dragStart, let dragCurrent else { return nil }
        let rect = Self.rect(from: dragStart, to: dragCurrent).intersection(contentFrame)
        return rect.isNull ? nil : rect
    }

    var body: some View {
        let shown = drawnFrame ?? currentFrame
        return ZStack(alignment: .topLeading) {
            if let shown {
                dimming(around: shown)
            }
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .gesture(drag)
            if let shown {
                outline(shown, isDrawing: drawnFrame != nil)
            }
        }
        .onHover { inside in
            if inside {
                NSCursor.crosshair.push()
            } else {
                NSCursor.pop()
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Crop picker")
        .accessibilityValue(accessibilityState)
        .accessibilityHint("Drag over the part of the recording to keep")
    }

    private var accessibilityState: String {
        currentFrame == nil ? "Whole recording" : "Cropped to \(pixelSize(of: currentFrame ?? .zero)) pixels"
    }

    /// Darkens the recording outside `frame`.
    private func dimming(around frame: CGRect) -> some View {
        Path { path in
            path.addRect(contentFrame)
            path.addRect(frame)
        }
        .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    private func outline(_ frame: CGRect, isDrawing: Bool) -> some View {
        let dash: [CGFloat] = isDrawing ? [] : [6, 4]
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(Color.white, style: StrokeStyle(lineWidth: 2, dash: dash))
                .shadow(color: .black.opacity(0.35), radius: 2)
                .frame(width: max(frame.width, 1), height: max(frame.height, 1))
                .offset(x: frame.minX, y: frame.minY)
            Text(pixelSize(of: frame))
                .font(DS.Typeface.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.black.opacity(0.6)))
                .position(x: frame.midX, y: max(frame.minY - 12, 10))
        }
        .allowsHitTesting(false)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragStart == nil {
                    dragStart = value.startLocation
                }
                dragCurrent = value.location
            }
            .onEnded { value in
                let drawn = Self.rect(from: dragStart ?? value.startLocation, to: value.location)
                dragStart = nil
                dragCurrent = nil
                guard drawn.width >= Self.minimumSize, drawn.height >= Self.minimumSize,
                      let source = ZoomKeyframeEditor.sourceRect(forSelection: drawn, contentFrame: contentFrame, visibleCrop: .fullFrame)
                else { return }
                editor.setSourceCrop(source)
            }
    }

    /// `frame`'s size in recording pixels, like "1440 × 900".
    private func pixelSize(of frame: CGRect) -> String {
        guard contentFrame.width > 0, contentFrame.height > 0 else { return "" }
        let width = frame.width / contentFrame.width * editor.sourceSize.width
        let height = frame.height / contentFrame.height * editor.sourceSize.height
        return "\(String(Int(width.rounded()))) × \(String(Int(height.rounded())))"
    }

    private static func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
}
