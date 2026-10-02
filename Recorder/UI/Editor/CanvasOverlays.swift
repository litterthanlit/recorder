import AppKit
import SwiftUI

/// Tools drawn over the canvas: picking an area for a new zoom, aiming the selected
/// zoom, and moving the selected text or blur. Clicking the picture selects the text or
/// blur under the pointer.
///
/// Sizes are in view points with a top-left origin. Zoom focus and blur boxes live in
/// normalized source space (bottom-left origin) and are mapped through what the preview
/// shows at the playhead.
struct CanvasOverlay: View {
    @ObservedObject var editor: ProjectEditor
    @ObservedObject var playback: EditorPlayback
    let canvasSize: CGSize

    /// While a zoom is aimed or the crop drawn, the preview shows the whole recording.
    private var showsWholeRecording: Bool {
        editor.isEditingZoomFocus || editor.isCropMode
    }

    private var contentFrame: CGRect {
        let style = editor.editSettings.exportStyle
        let size = showsWholeRecording ? editor.sourceSize : editor.contentSize
        let aspect = size.width / max(size.height, 1)
        return CanvasLayout.contentFrame(
            canvas: canvasSize,
            contentAspect: aspect,
            paddingRatio: style.backgroundEnabled ? style.paddingRatio : 0
        )
    }

    private var sourceTime: TimeInterval {
        editor.timeline.sourceTime(forOutput: playback.time)
    }

    /// The part of the recording on screen: all of it while aiming a zoom or cropping.
    private var visibleCrop: NormalizedRect {
        showsWholeRecording ? .fullFrame : editor.interpolator.cropRect(at: sourceTime)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { location in
                    selectItem(at: location)
                }
            tools
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
    }

    @ViewBuilder
    private var tools: some View {
        if editor.isCropMode {
            CropSelection(editor: editor, contentFrame: contentFrame)
        } else if editor.isManualZoomMode {
            ManualZoomSelection(editor: editor, contentFrame: contentFrame, visibleCrop: visibleCrop)
        } else if editor.isEditingZoomFocus, let keyframe = editor.selectedKeyframe {
            ZoomFocusEditor(editor: editor, keyframe: keyframe, contentFrame: contentFrame)
        } else if let region = editor.selectedBlur {
            BlurBoxEditor(editor: editor, region: region, contentFrame: contentFrame, visibleCrop: visibleCrop)
        } else if let overlay = editor.selectedText {
            TextBoxEditor(editor: editor, overlay: overlay, canvasSize: canvasSize)
        }
    }

    /// Selects the text or blur showing under `location`, or clears the selection.
    private func selectItem(at location: CGPoint) {
        guard !editor.isManualZoomMode, !editor.isEditingZoomFocus, !editor.isCropMode else { return }
        let time = sourceTime
        for overlay in editor.editSettings.textOverlays.reversed() where overlay.opacity(at: time) > 0 {
            if TextPlateLayout.viewFrame(for: overlay, canvas: canvasSize).contains(location) {
                editor.select(.text(overlay.id))
                return
            }
        }
        let crop = visibleCrop
        for region in editor.editSettings.blurRegions.reversed() where region.isActive(at: time) {
            let rect = ZoomKeyframeEditor.viewRect(forSource: region.rect, contentFrame: contentFrame, visibleCrop: crop)
            if rect.contains(location) {
                editor.select(.blur(region.id))
                return
            }
        }
        editor.select(nil)
    }
}

// MARK: - Shared pieces

/// A corner of a box being resized.
enum BoxCorner: CaseIterable, Identifiable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var id: Self { self }

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    /// The corner diagonally across.
    var opposite: BoxCorner {
        switch self {
        case .topLeft: return .bottomRight
        case .topRight: return .bottomLeft
        case .bottomLeft: return .topRight
        case .bottomRight: return .topLeft
        }
    }

    var label: String {
        switch self {
        case .topLeft: return "top left"
        case .topRight: return "top right"
        case .bottomLeft: return "bottom left"
        case .bottomRight: return "bottom right"
        }
    }
}

/// A round handle on a box corner.
private struct CornerHandle: View {
    var tint: Color = DS.Palette.accent

    var body: some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().strokeBorder(tint, lineWidth: 2))
            .frame(width: 11, height: 11)
            .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
    }
}

private func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
    CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
}

// MARK: - New zoom

/// Drag over the picture to pick the area a new zoom shows.
private struct ManualZoomSelection: View {
    let editor: ProjectEditor
    let contentFrame: CGRect
    let visibleCrop: NormalizedRect

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?

    var body: some View {
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
                            let selection = rect(from: dragStart ?? value.startLocation, to: value.location)
                            dragStart = nil
                            dragCurrent = nil
                            guard selection.width > 8, selection.height > 8,
                                  let sourceRect = ZoomKeyframeEditor.sourceRect(
                                      forSelection: selection,
                                      contentFrame: contentFrame,
                                      visibleCrop: visibleCrop
                                  )
                            else { return }
                            editor.addManualZoom(from: sourceRect)
                        }
                )

            Rectangle()
                .strokeBorder(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .frame(width: contentFrame.width, height: contentFrame.height)
                .offset(x: contentFrame.minX, y: contentFrame.minY)
                .allowsHitTesting(false)

            if let dragStart, let dragCurrent {
                let selection = rect(from: dragStart, to: dragCurrent).intersection(contentFrame)
                if !selection.isNull {
                    Rectangle()
                        .strokeBorder(DS.Palette.manualZoomTrack, lineWidth: 2)
                        .background(DS.Palette.manualZoomTrack.opacity(0.15))
                        .frame(width: selection.width, height: selection.height)
                        .offset(x: selection.minX, y: selection.minY)
                        .allowsHitTesting(false)
                }
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
        .accessibilityLabel("Zoom area picker")
        .accessibilityHint("Drag over the preview to choose the area to zoom into")
    }
}

// MARK: - Zoom focus

/// The selected zoom's view of the recording, drawn over the unzoomed picture: drag it
/// to aim the zoom, drag a corner to zoom closer or wider.
private struct ZoomFocusEditor: View {
    let editor: ProjectEditor
    let keyframe: ZoomKeyframe
    let contentFrame: CGRect

    @State private var origin: ZoomKeyframe?

    private static let actionName = "Aim Zoom"

    /// A view point as a normalized source point (bottom-left origin).
    private func normalized(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - contentFrame.minX) / max(contentFrame.width, 1),
            y: (contentFrame.maxY - point.y) / max(contentFrame.height, 1)
        )
    }

    /// What the video shows at rest (the crop); the zoom stays inside it.
    private var base: CGRect {
        editor.editSettings.cropBase
    }

    var body: some View {
        let focus = ZoomKeyframeEditor.focusRect(for: keyframe, base: base)
        let frame = ZoomKeyframeEditor.viewRect(forSource: focus, contentFrame: contentFrame, visibleCrop: .fullFrame)
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(contentFrame)
                path.addRect(frame)
            }
            .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Rectangle()
                .strokeBorder(Color.white, lineWidth: 2)
                .background(Color.white.opacity(0.001))
                .shadow(color: .black.opacity(0.35), radius: 2)
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .gesture(moveGesture)
                .accessibilityElement()
                .accessibilityLabel("Zoom focus, \(String(format: "%.1f", Double(keyframe.scale))) times")
                .accessibilityHint("Drag to aim the zoom")

            Text(String(format: "%.1f×", Double(keyframe.scale)))
                .font(DS.Typeface.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.black.opacity(0.6)))
                .position(x: frame.midX, y: max(frame.minY - 12, 10))
                .allowsHitTesting(false)

            ForEach(BoxCorner.allCases) { corner in
                CornerHandle()
                    .position(corner.point(in: frame))
                    .gesture(resizeGesture(corner, frame: frame))
                    .accessibilityLabel("Resize zoom from the \(corner.label) corner")
            }
        }
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = begin()
                let dx = value.translation.width / max(contentFrame.width, 1)
                let dy = -value.translation.height / max(contentFrame.height, 1)
                let target = CGPoint(x: start.centerX + dx, y: start.centerY + dy)
                let moved = ZoomKeyframeEditor.keyframe(start, movingFocusTo: target, base: base)
                editor.updateKeyframe(moved, commit: false, actionName: Self.actionName)
            }
            .onEnded { _ in finish() }
    }

    private func resizeGesture(_ corner: BoxCorner, frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = begin()
                let startFrame = ZoomKeyframeEditor.viewRect(
                    forSource: ZoomKeyframeEditor.focusRect(for: start, base: base),
                    contentFrame: contentFrame,
                    visibleCrop: .fullFrame
                )
                let fixed = normalized(corner.opposite.point(in: startFrame))
                let moving = corner.point(in: startFrame)
                let pointer = normalized(CGPoint(x: moving.x + value.translation.width, y: moving.y + value.translation.height))
                // The zoom keeps the crop's shape (square without one).
                let ratio: CGFloat = base.height > 0 ? base.width / base.height : 1
                let width = max(abs(pointer.x - fixed.x), abs(pointer.y - fixed.y) * ratio)
                let height = width / ratio
                let box = CGRect(
                    x: pointer.x < fixed.x ? fixed.x - width : fixed.x,
                    y: pointer.y < fixed.y ? fixed.y - height : fixed.y,
                    width: width,
                    height: height
                )
                let resized = ZoomKeyframeEditor.keyframe(start, focusingOn: box, base: base)
                editor.updateKeyframe(resized, commit: false, actionName: Self.actionName)
            }
            .onEnded { _ in finish() }
    }

    /// The zoom as it was when the drag started.
    private func begin() -> ZoomKeyframe {
        if let origin {
            return origin
        }
        origin = keyframe
        editor.beginInteractiveEdit(Self.actionName)
        return keyframe
    }

    private func finish() {
        origin = nil
        editor.endInteractiveEdit()
    }
}

// MARK: - Blur box

/// The selected blur region: drag it over what to hide, drag a corner to resize.
private struct BlurBoxEditor: View {
    let editor: ProjectEditor
    let region: BlurRegion
    let contentFrame: CGRect
    let visibleCrop: NormalizedRect

    @State private var origin: BlurRegion?

    private static let actionName = "Move Blur"

    var body: some View {
        let frame = ZoomKeyframeEditor.viewRect(forSource: region.rect, contentFrame: contentFrame, visibleCrop: visibleCrop)
        let tint = DS.Palette.blurTrack
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(tint, style: StrokeStyle(lineWidth: 2, dash: [6, 3]))
                .background(tint.opacity(0.1))
                .frame(width: max(frame.width, 1), height: max(frame.height, 1))
                .position(x: frame.midX, y: frame.midY)
                .gesture(moveGesture)
                .accessibilityElement()
                .accessibilityLabel("\(region.kind.label) box")
                .accessibilityHint("Drag to move it over what to hide")

            ForEach(BoxCorner.allCases) { corner in
                CornerHandle(tint: tint)
                    .position(corner.point(in: frame))
                    .gesture(resizeGesture(corner))
                    .accessibilityLabel("Resize from the \(corner.label) corner")
            }
        }
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = begin()
                let dx = value.translation.width / max(contentFrame.width, 1) * visibleCrop.width
                let dy = -value.translation.height / max(contentFrame.height, 1) * visibleCrop.height
                let id = start.id
                editor.updateBlur(id, actionName: Self.actionName, continuous: true) { region in
                    region.rect = start.rect.offsetBy(dx: dx, dy: dy)
                }
            }
            .onEnded { _ in finish() }
    }

    private func resizeGesture(_ corner: BoxCorner) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = begin()
                let startFrame = ZoomKeyframeEditor.viewRect(forSource: start.rect, contentFrame: contentFrame, visibleCrop: visibleCrop)
                let fixed = corner.opposite.point(in: startFrame)
                let moving = corner.point(in: startFrame)
                let pointer = CGPoint(x: moving.x + value.translation.width, y: moving.y + value.translation.height)
                let resized = rect(from: fixed, to: pointer)
                let source = ZoomKeyframeEditor.unclippedSourceRect(forView: resized, contentFrame: contentFrame, visibleCrop: visibleCrop)
                editor.updateBlur(start.id, actionName: Self.actionName, continuous: true) { region in
                    region.rect = source
                }
            }
            .onEnded { _ in finish() }
    }

    private func begin() -> BlurRegion {
        if let origin {
            return origin
        }
        origin = region
        editor.beginInteractiveEdit(Self.actionName)
        return region
    }

    private func finish() {
        origin = nil
        editor.endInteractiveEdit()
    }
}

// MARK: - Text box

/// The selected text: drag it where it should go on the canvas.
private struct TextBoxEditor: View {
    let editor: ProjectEditor
    let overlay: TextOverlay
    let canvasSize: CGSize

    @State private var origin: CGPoint?

    private static let actionName = "Move Text"

    var body: some View {
        let frame = TextPlateLayout.viewFrame(for: overlay, canvas: canvasSize).insetBy(dx: -4, dy: -4)
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(DS.Palette.textTrack, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            .background(DS.Palette.textTrack.opacity(0.06))
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start: CGPoint
                        if let origin {
                            start = origin
                        } else {
                            start = overlay.center
                            origin = start
                            editor.beginInteractiveEdit(Self.actionName)
                        }
                        let center = CGPoint(
                            x: start.x + value.translation.width / max(canvasSize.width, 1),
                            y: start.y + value.translation.height / max(canvasSize.height, 1)
                        )
                        editor.updateText(overlay.id, actionName: Self.actionName, continuous: true) { $0.center = center }
                    }
                    .onEnded { _ in
                        origin = nil
                        editor.endInteractiveEdit()
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Text: \(overlay.text)")
            .accessibilityHint("Drag to move it")
    }
}
