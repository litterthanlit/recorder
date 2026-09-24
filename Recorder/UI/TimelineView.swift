import AppKit
import SwiftUI

struct TimelineView: View {
    @ObservedObject var editor: ProjectEditor

    @State private var dragOrigin: ZoomKeyframe?
    @State private var resizeOrigin: ZoomKeyframe?
    @State private var trimDrag: TrimDrag?

    private enum TrimDrag {
        case start
        case end
    }

    private enum ZoomEdge {
        case start
        case end
    }

    private let trackHeight: CGFloat = 52
    /// Hit area of a trim handle; the visible bar is narrower.
    private let trimHandleHitWidth: CGFloat = 16
    /// Step for VoiceOver adjustments (and matches the editor's keyboard nudge).
    private let accessibilityStep: TimeInterval = 0.1

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Timeline")
                    .font(.headline)
                Spacer()
                Text("\(editor.keyframes.count) zooms · trim \(formatTime(editor.trimStart))–\(formatTime(editor.trimEnd))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geometry in
                let width = geometry.size.width
                let duration = max(editor.duration, 0.01)

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.06))

                    trimExcludedRegions(width: width, duration: duration)

                    ForEach(editor.keyframes) { keyframe in
                        keyframeBlock(keyframe, timelineWidth: width, duration: duration)
                    }

                    trimHandle(at: editor.trimStart, width: width, duration: duration, kind: .start)
                    trimHandle(at: editor.trimEnd, width: width, duration: duration, kind: .end)

                    playhead(in: width, duration: duration)
                }
                .frame(height: trackHeight)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard trimDrag == nil else { return }
                            seekFromLocation(value.location.x, width: width, duration: duration)
                        }
                )
            }
            .frame(height: trackHeight)

            timeRuler
        }
    }

    private func trimExcludedRegions(width: CGFloat, duration: TimeInterval) -> some View {
        let startX = CGFloat(editor.trimStart / duration) * width
        let endX = CGFloat(editor.trimEnd / duration) * width

        return ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.black.opacity(0.12))
                .frame(width: startX, height: trackHeight)

            Rectangle()
                .fill(Color.black.opacity(0.12))
                .frame(width: width - endX, height: trackHeight)
                .offset(x: endX)
        }
    }

    private func trimHandle(at time: TimeInterval, width: CGFloat, duration: TimeInterval, kind: TrimDrag) -> some View {
        let x = CGFloat(time / duration) * width

        return ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(kind == .start ? Color.green.opacity(0.9) : Color.orange.opacity(0.9))
                .frame(width: 6, height: trackHeight - 4)
            // Grip marks so the handle reads as draggable.
            VStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 2, height: 2)
                }
            }
        }
        .frame(width: trimHandleHitWidth, height: trackHeight)
        .contentShape(Rectangle())
        .offset(x: x - trimHandleHitWidth / 2)
        .onHover { inside in
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind == .start ? "Trim start" : "Trim end")
        .accessibilityValue(spokenTime(time))
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? accessibilityStep : -accessibilityStep
            if kind == .start {
                editor.setTrimStart(editor.trimStart + step)
            } else {
                editor.setTrimEnd(editor.trimEnd + step)
            }
        }
        .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if trimDrag == nil {
                            editor.beginInteractiveEdit("Trim")
                        }
                        trimDrag = kind
                        let fraction = max(0, min(1, value.location.x / width))
                        let newTime = duration * Double(fraction)
                        if kind == .start {
                            editor.setTrimStart(newTime)
                        } else {
                            editor.setTrimEnd(newTime)
                        }
                    }
                    .onEnded { _ in
                        trimDrag = nil
                        editor.endInteractiveEdit()
                    }
            )
    }

    private func keyframeBlock(_ keyframe: ZoomKeyframe, timelineWidth: CGFloat, duration: TimeInterval) -> some View {
        let x = CGFloat(keyframe.startTime / duration) * timelineWidth
        let blockWidth = max(
            CGFloat((keyframe.endTime - keyframe.startTime) / duration) * timelineWidth,
            16
        )
        let isSelected = editor.selectedKeyframeID == keyframe.id
        let color: Color = keyframe.source == .manual ? .orange : .blue
        // Leave the middle of short blocks free for moving.
        let edgeWidth = min(8, blockWidth / 4)

        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(isSelected ? 0.55 : 0.35))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isSelected ? color : color.opacity(0.6), lineWidth: isSelected ? 2 : 1)
                }
                .frame(width: blockWidth, height: trackHeight - 12)
                .offset(x: x, y: 6)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            editor.selectKeyframe(keyframe.id)
                            if dragOrigin?.id != keyframe.id {
                                dragOrigin = keyframe
                                editor.beginInteractiveEdit("Move Zoom")
                            }
                            guard let dragOrigin else { return }
                            let deltaTime = Double(value.translation.width / timelineWidth) * duration
                            var updated = ZoomKeyframeEditor.moveKeyframe(
                                dragOrigin,
                                by: deltaTime,
                                duration: duration
                            )
                            updated = ZoomKeyframeEditor.clampKeyframe(updated, duration: duration)
                            editor.updateKeyframe(updated, commit: false)
                        }
                        .onEnded { _ in
                            dragOrigin = nil
                            // Resolves overlaps and records the whole drag as one undo step.
                            editor.endInteractiveEdit()
                            editor.selectKeyframe(keyframe.id)
                        }
                )
                .onTapGesture {
                    editor.selectKeyframe(keyframe.id)
                    editor.seek(to: keyframe.peakTime)
                }

            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .offset(
                    x: x + CGFloat((keyframe.peakTime - keyframe.startTime) / duration) * timelineWidth - 4,
                    y: trackHeight / 2 - 4
                )
                .allowsHitTesting(false)

            resizeHandle(keyframe, edge: .start, color: color, isSelected: isSelected, width: edgeWidth, timelineWidth: timelineWidth, duration: duration)
                .offset(x: x, y: 6)
            resizeHandle(keyframe, edge: .end, color: color, isSelected: isSelected, width: edgeWidth, timelineWidth: timelineWidth, duration: duration)
                .offset(x: x + blockWidth - edgeWidth, y: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(keyframe.source == .manual ? "Manual" : "Auto") zoom, \(String(format: "%.1f", Double(keyframe.scale)))x"
        )
        .accessibilityValue("\(spokenTime(keyframe.startTime)) to \(spokenTime(keyframe.endTime))")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction {
            editor.selectKeyframe(keyframe.id)
            editor.seek(to: keyframe.peakTime)
        }
        .accessibilityAdjustableAction { direction in
            editor.selectKeyframe(keyframe.id)
            editor.moveSelectedKeyframe(by: direction == .increment ? accessibilityStep : -accessibilityStep)
        }
        .accessibilityAction(named: "Delete") {
            editor.selectKeyframe(keyframe.id)
            editor.deleteSelectedKeyframe()
        }
    }

    /// Drag area on one edge of a zoom block that changes when the zoom starts or ends.
    private func resizeHandle(
        _ keyframe: ZoomKeyframe,
        edge: ZoomEdge,
        color: Color,
        isSelected: Bool,
        width: CGFloat,
        timelineWidth: CGFloat,
        duration: TimeInterval
    ) -> some View {
        Rectangle()
            .fill(Color.clear)
            .overlay {
                if isSelected {
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: trackHeight - 28)
                }
            }
            .frame(width: width, height: trackHeight - 12)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if resizeOrigin?.id != keyframe.id {
                            resizeOrigin = keyframe
                            editor.selectKeyframe(keyframe.id)
                            editor.beginInteractiveEdit("Resize Zoom")
                        }
                        guard let origin = resizeOrigin else { return }
                        let deltaTime = Double(value.translation.width / timelineWidth) * duration
                        let updated: ZoomKeyframe
                        switch edge {
                        case .start:
                            updated = ZoomKeyframeEditor.resizeKeyframeStart(
                                origin, to: origin.startTime + deltaTime, duration: duration
                            )
                        case .end:
                            updated = ZoomKeyframeEditor.resizeKeyframeEnd(
                                origin, to: origin.endTime + deltaTime, duration: duration
                            )
                        }
                        editor.updateKeyframe(updated, commit: false)
                    }
                    .onEnded { _ in
                        resizeOrigin = nil
                        // Resolves overlaps and records the whole drag as one undo step.
                        editor.endInteractiveEdit()
                    }
            )
    }

    private func playhead(in width: CGFloat, duration: TimeInterval) -> some View {
        let x = CGFloat(editor.playheadTime / duration) * width

        return Rectangle()
            .fill(Color.red)
            .frame(width: 2, height: trackHeight)
            .offset(x: x)
    }

    private var timeRuler: some View {
        HStack {
            Text(formatTime(0))
            Spacer()
            Text(formatTime(editor.duration / 2))
            Spacer()
            Text(formatTime(editor.duration))
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private func seekFromLocation(_ x: CGFloat, width: CGFloat, duration: TimeInterval) {
        let fraction = max(0, min(1, x / width))
        editor.seek(to: duration * Double(fraction))
    }

    private func spokenTime(_ time: TimeInterval) -> String {
        String(format: "%.1f seconds", time)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let totalSeconds = Int(time.rounded(.down))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%01d:%02d", minutes, seconds)
    }
}
