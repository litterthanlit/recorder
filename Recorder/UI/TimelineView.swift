import SwiftUI

struct TimelineView: View {
    @ObservedObject var editor: ProjectEditor

    @State private var dragOrigin: ZoomKeyframe?
    @State private var trimDrag: TrimDrag?

    private enum TrimDrag {
        case start
        case end
    }

    private let trackHeight: CGFloat = 52

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

        return RoundedRectangle(cornerRadius: 2)
            .fill(kind == .start ? Color.green.opacity(0.9) : Color.orange.opacity(0.9))
            .frame(width: 4, height: trackHeight - 4)
            .offset(x: x - 2, y: 2)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
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
                            }
                            guard let dragOrigin else { return }
                            let deltaTime = Double(value.translation.width / timelineWidth) * duration
                            var updated = ZoomKeyframeEditor.moveKeyframe(
                                dragOrigin,
                                by: deltaTime,
                                duration: duration
                            )
                            updated = ZoomKeyframeEditor.clampKeyframe(updated, duration: duration)
                            editor.updateKeyframe(updated)
                        }
                        .onEnded { _ in
                            dragOrigin = nil
                            editor.resolveKeyframeOverlaps()
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
        }
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

    private func formatTime(_ time: TimeInterval) -> String {
        let totalSeconds = Int(time.rounded(.down))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%01d:%02d", minutes, seconds)
    }
}
