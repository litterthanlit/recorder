import AppKit
import SwiftUI

/// Everything inside the timeline's scroll view, in content coordinates (x = output time
/// × points per second).
struct TimelineContent: View {
    @ObservedObject var editor: ProjectEditor
    let playback: EditorPlayback
    @ObservedObject var media: TimelineMedia
    let scale: TimelineScale
    /// The part of the content on screen; drawing is limited to it.
    let visibleRange: ClosedRange<CGFloat>

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                RulerView(editor: editor, playback: playback, scale: scale, visibleRange: visibleRange)
                    .frame(height: TimelineMetrics.rulerHeight)
                ClipTrack(editor: editor, media: media, scale: scale, visibleRange: visibleRange)
                    .frame(height: TimelineMetrics.clipHeight)
                    .trackSeparator()
                ZoomTrack(editor: editor, scale: scale)
                    .frame(height: TimelineMetrics.zoomHeight)
                    .trackSeparator()
                ItemTrack(editor: editor, kind: .text, scale: scale, visibleRange: visibleRange)
                    .frame(height: TimelineMetrics.itemHeight)
                    .trackSeparator()
                ItemTrack(editor: editor, kind: .blur, scale: scale, visibleRange: visibleRange)
                    .frame(height: TimelineMetrics.itemHeight)
                    .trackSeparator()
                WaveformTrack(editor: editor, media: media, scale: scale, visibleRange: visibleRange)
                    .frame(height: TimelineMetrics.audioHeight)
                    .trackSeparator()
            }
            PlayheadLine(playback: playback, scale: scale, height: TimelineMetrics.rulerHeight + TimelineMetrics.tracksHeight)
        }
    }
}

private extension View {
    func trackSeparator() -> some View {
        overlay(alignment: .bottom) {
            Rectangle()
                .fill(DS.Palette.separator.opacity(0.5))
                .frame(height: 0.5)
                .allowsHitTesting(false)
        }
    }
}

/// Snapping for drags on the timeline, in output time.
private struct TimelineSnap {
    let times: [TimeInterval]
    let tolerance: TimeInterval

    /// The playhead, clip boundaries, and the edges of every zoom, text and blur except
    /// `excluding`.
    @MainActor
    init(editor: ProjectEditor, scale: TimelineScale, excluding: UUID?) {
        let timeline = editor.timeline
        var times = timeline.outputStarts
        times.append(timeline.outputDuration)
        times.append(editor.playheadTime)
        for keyframe in editor.keyframes where keyframe.id != excluding {
            times.append(timeline.outputTimeClamped(forSource: keyframe.startTime))
            times.append(timeline.outputTimeClamped(forSource: keyframe.endTime))
        }
        for overlay in editor.editSettings.textOverlays where overlay.id != excluding {
            times.append(timeline.outputTimeClamped(forSource: overlay.span.start))
            times.append(timeline.outputTimeClamped(forSource: overlay.span.end))
        }
        for region in editor.editSettings.blurRegions where region.id != excluding {
            times.append(timeline.outputTimeClamped(forSource: region.span.start))
            times.append(timeline.outputTimeClamped(forSource: region.span.end))
        }
        self.times = times
        tolerance = 8 / Double(max(scale.pointsPerSecond, 0.01))
    }

    func callAsFunction(_ time: TimeInterval) -> TimeInterval {
        TimelineSnapper.snap(time, to: times, tolerance: tolerance)
    }
}

// MARK: - Ruler and playhead

/// Time labels; click or drag to move the playhead.
private struct RulerView: View {
    let editor: ProjectEditor
    @ObservedObject var playback: EditorPlayback
    let scale: TimelineScale
    let visibleRange: ClosedRange<CGFloat>

    var body: some View {
        let width = visibleRange.upperBound - visibleRange.lowerBound
        let start = visibleRange.lowerBound
        return ZStack(alignment: .topLeading) {
            Canvas { context, size in
                let pointsPerSecond = max(scale.pointsPerSecond, 0.01)
                let intervals = TimelineRuler.intervals(pointsPerSecond: pointsPerSecond)
                let ticks = TimelineRuler.ticks(
                    from: TimeInterval(start / pointsPerSecond),
                    to: min(TimeInterval((start + size.width) / pointsPerSecond), scale.duration),
                    pointsPerSecond: pointsPerSecond
                )
                for tick in ticks {
                    let x = scale.x(for: tick.time) - start
                    let height: CGFloat = tick.isMajor ? 9 : 4
                    let line = Path(CGRect(x: x, y: size.height - height, width: 1, height: height))
                    context.fill(line, with: .color(Color.secondary.opacity(tick.isMajor ? 0.7 : 0.35)))
                    if tick.isMajor {
                        let label = Text(TimelineRuler.label(for: tick.time, majorInterval: intervals.major))
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundColor(.secondary)
                        context.draw(label, at: CGPoint(x: x + 4, y: 3), anchor: .topLeading)
                    }
                }
            }
            .frame(width: max(width, 1), height: TimelineMetrics.rulerHeight)
            .offset(x: start)
            .allowsHitTesting(false)
        }
        .frame(width: max(scale.contentWidth, 1), height: TimelineMetrics.rulerHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    editor.seek(to: scale.time(for: value.location.x))
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Playhead")
        .accessibilityValue(Timecode.spoken(playback.time))
        .accessibilityAdjustableAction { direction in
            editor.step(seconds: direction == .increment ? 1 : -1)
        }
    }
}

/// The playhead across all tracks. It also carries the scroll anchor that keeps the
/// playhead in view.
struct PlayheadLine: View {
    @ObservedObject var playback: EditorPlayback
    let scale: TimelineScale
    let height: CGFloat

    static let anchorID = "timeline.playhead"

    var body: some View {
        let x = scale.x(for: playback.time)
        return ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: 1, height: 1)
                .id(Self.anchorID)
                .position(x: x, y: 0.5)
            Rectangle()
                .fill(DS.Palette.playhead)
                .frame(width: 1.5, height: height)
                .offset(x: x - 0.75)
            PlayheadHead()
                .fill(DS.Palette.playhead)
                .frame(width: 11, height: 9)
                .offset(x: x - 5.5)
        }
        .frame(height: height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct PlayheadHead: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY * 0.55))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY * 0.55))
        path.closeSubpath()
        return path
    }
}

// MARK: - Clips

private struct ClipTrack: View {
    @ObservedObject var editor: ProjectEditor
    @ObservedObject var media: TimelineMedia
    let scale: TimelineScale
    let visibleRange: ClosedRange<CGFloat>

    var body: some View {
        let timeline = editor.timeline
        let starts = timeline.outputStarts
        let start = visibleRange.lowerBound
        let width = visibleRange.upperBound - visibleRange.lowerBound
        return ZStack(alignment: .topLeading) {
            FilmstripCanvas(
                timeline: timeline,
                starts: starts,
                media: media,
                scale: scale,
                visibleStart: start
            )
            .frame(width: max(width, 1), height: TimelineMetrics.clipHeight - 8)
            .offset(x: start, y: 4)
            .allowsHitTesting(false)

            ForEach(Array(timeline.segments.enumerated()), id: \.element.id) { index, segment in
                ClipBlock(
                    editor: editor,
                    segment: segment,
                    index: index,
                    count: timeline.segments.count,
                    outputStart: starts[index],
                    scale: scale
                )
            }
        }
        .frame(width: max(scale.contentWidth, 1), height: TimelineMetrics.clipHeight, alignment: .topLeading)
    }
}

/// Thumbnails of the recording under the clips, drawn only where they're on screen.
private struct FilmstripCanvas: View {
    let timeline: EditTimeline
    let starts: [TimeInterval]
    @ObservedObject var media: TimelineMedia
    let scale: TimelineScale
    let visibleStart: CGFloat

    var body: some View {
        Canvas { context, size in
            let tileHeight = size.height
            let tileWidth = max(tileHeight * media.aspect, 8)
            for (index, segment) in timeline.segments.enumerated() {
                let clipX = scale.x(for: starts[index]) - visibleStart
                let clipWidth = max(scale.x(for: segment.outputDuration) - 2, 1)
                let clipRect = CGRect(x: clipX, y: 0, width: clipWidth, height: tileHeight)
                guard clipRect.maxX > 0, clipRect.minX < size.width else { continue }
                context.drawLayer { layer in
                    layer.clip(to: Path(roundedRect: clipRect, cornerRadius: 6, style: .continuous))
                    layer.fill(Path(clipRect), with: .color(Color.primary.opacity(0.08)))
                    var tile = max(0, Int((-clipX / tileWidth).rounded(.down)))
                    while true {
                        let tileX = clipX + CGFloat(tile) * tileWidth
                        if tileX > min(clipRect.maxX, size.width) {
                            break
                        }
                        let outputTime = scale.time(for: tileX + visibleStart + tileWidth / 2)
                        let sourceTime = timeline.sourceTime(forOutput: min(outputTime, starts[index] + segment.outputDuration))
                        if let image = media.thumbnail(near: sourceTime) {
                            layer.draw(
                                Image(decorative: image, scale: 1),
                                in: CGRect(x: tileX, y: 0, width: tileWidth, height: tileHeight)
                            )
                        }
                        tile += 1
                    }
                }
            }
        }
    }
}

/// One clip: its outline, speed, and handles to trim either end.
private struct ClipBlock: View {
    @ObservedObject var editor: ProjectEditor
    let segment: EditSegment
    let index: Int
    let count: Int
    let outputStart: TimeInterval
    let scale: TimelineScale

    @State private var trimOrigin: TimeSpan?

    private enum Edge {
        case leading
        case trailing
    }

    private var isSelected: Bool {
        editor.selectedSegmentID == segment.id
    }

    var body: some View {
        let x = scale.x(for: outputStart)
        let width = max(scale.x(for: segment.outputDuration) - 2, 3)
        let height = TimelineMetrics.clipHeight - 8
        let isSped = abs(segment.speed - 1) > 0.001
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isSelected ? DS.Palette.accent : Color.primary.opacity(0.18), lineWidth: isSelected ? 2 : 1)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.black.opacity(isSelected ? 0 : 0.08))
                )
                .contentShape(Rectangle())
                .onTapGesture { location in
                    editor.select(.clip(segment.id))
                    editor.seek(to: scale.time(for: x + location.x))
                }
                .contextMenu { menu }

            if isSped, width > 34 {
                Text(Timecode.speed(segment.speed))
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(DS.Palette.accentFill))
                    .padding(5)
                    .allowsHitTesting(false)
            }

            trimHandle(.leading, height: height)
            trimHandle(.trailing, height: height)
                .offset(x: width - 8)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .offset(x: x, y: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Clip \(index + 1) of \(count)\(isSped ? ", \(Timecode.speed(segment.speed))" : "")")
        .accessibilityValue(Timecode.spoken(segment.outputDuration))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction {
            editor.select(.clip(segment.id))
            editor.seek(to: outputStart)
        }
        .accessibilityAction(named: "Delete") {
            editor.deleteSegment(segment.id)
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Split at Playhead") { editor.splitAtPlayhead() }
        Menu("Speed") {
            ForEach([0.5, 1, 1.5, 2, 4, 8], id: \.self) { speed in
                Button(Timecode.speed(speed)) { editor.setSpeed(speed, forSegment: segment.id) }
            }
        }
        Divider()
        Button("Delete Clip", role: .destructive) { editor.deleteSegment(segment.id) }
            .disabled(count < 2)
    }

    private func trimHandle(_ edge: Edge, height: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .overlay {
                if isSelected {
                    Capsule()
                        .fill(DS.Palette.accent)
                        .frame(width: 3, height: height * 0.5)
                }
            }
            .frame(width: 8, height: height)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if trimOrigin == nil {
                            trimOrigin = segment.source
                            editor.select(.clip(segment.id))
                            editor.beginInteractiveEdit("Trim Clip")
                        }
                        guard let origin = trimOrigin else { return }
                        // Output points to source seconds: faster clips cover more source.
                        let delta = Double(value.translation.width / max(scale.pointsPerSecond, 0.01)) * segment.speed
                        switch edge {
                        case .leading:
                            editor.setSegmentSourceRange(segment.id, start: origin.start + delta)
                        case .trailing:
                            editor.setSegmentSourceRange(segment.id, end: origin.end + delta)
                        }
                    }
                    .onEnded { _ in
                        trimOrigin = nil
                        editor.endInteractiveEdit()
                    }
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Zooms

private struct ZoomTrack: View {
    @ObservedObject var editor: ProjectEditor
    let scale: TimelineScale

    @State private var creation: (start: CGFloat, end: CGFloat)?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .gesture(createGesture)

            if editor.keyframes.isEmpty {
                Text("Drag here to add a zoom")
                    .font(DS.Typeface.caption)
                    .foregroundStyle(DS.Palette.tertiaryText)
                    .padding(.leading, DS.Spacing.xs)
                    .frame(height: TimelineMetrics.zoomHeight)
                    .allowsHitTesting(false)
            }

            ForEach(editor.keyframes) { keyframe in
                ZoomBlock(editor: editor, keyframe: keyframe, scale: scale)
            }

            if let creation {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(DS.Palette.manualZoomTrack, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .background(DS.Palette.manualZoomTrack.opacity(0.15))
                    .frame(width: abs(creation.end - creation.start), height: TimelineMetrics.zoomHeight - 8)
                    .offset(x: min(creation.start, creation.end), y: 4)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: max(scale.contentWidth, 1), height: TimelineMetrics.zoomHeight, alignment: .topLeading)
    }

    /// Drag along empty track to add a zoom over that stretch; click to move the playhead.
    private var createGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if abs(value.translation.width) > 4 {
                    creation = (value.startLocation.x, value.location.x)
                }
            }
            .onEnded { value in
                defer { creation = nil }
                guard abs(value.translation.width) > 4 else {
                    editor.select(nil)
                    editor.seek(to: scale.time(for: value.location.x))
                    return
                }
                let timeline = editor.timeline
                let startOutput = scale.time(for: min(value.startLocation.x, value.location.x))
                let endOutput = scale.time(for: max(value.startLocation.x, value.location.x))
                let span = TimeSpan(
                    start: timeline.sourceTime(forOutput: startOutput),
                    end: timeline.sourceTime(forOutput: endOutput)
                )
                editor.addZoom(over: span)
            }
    }
}

private struct ZoomBlock: View {
    @ObservedObject var editor: ProjectEditor
    let keyframe: ZoomKeyframe
    let scale: TimelineScale

    @State private var drag: (origin: ZoomKeyframe, outputStart: TimeInterval, outputEnd: TimeInterval)?

    private enum Part {
        case body
        case start
        case end
    }

    private var isSelected: Bool {
        editor.selectedKeyframeID == keyframe.id
    }

    var body: some View {
        let timeline = editor.timeline
        let startOutput = timeline.outputTimeClamped(forSource: keyframe.startTime)
        let endOutput = timeline.outputTimeClamped(forSource: keyframe.endTime)
        let x = scale.x(for: startOutput)
        let width = scale.x(for: endOutput) - x
        let tint = keyframe.source == .manual ? DS.Palette.manualZoomTrack : DS.Palette.zoomTrack
        let height = TimelineMetrics.zoomHeight - 8
        let edgeWidth = min(8, max(width / 4, 2))

        return Group {
            if width >= 2 {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(tint.opacity(isSelected ? 0.55 : 0.3))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(isSelected ? tint : tint.opacity(0.7), lineWidth: isSelected ? 2 : 1)
                        )
                        .contentShape(Rectangle())
                        .gesture(dragGesture(.body, startOutput: startOutput, endOutput: endOutput))
                        .onTapGesture {
                            editor.select(.zoom(keyframe.id))
                            editor.seek(toSource: keyframe.peakTime)
                        }

                    if width > 46 {
                        Label(String(format: "%.1f×", Double(keyframe.scale)), systemImage: "plus.magnifyingglass")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Color.primary.opacity(0.85))
                            .padding(.leading, 6)
                            .frame(height: height)
                            .allowsHitTesting(false)
                    }

                    edge(.start, width: edgeWidth, height: height, startOutput: startOutput, endOutput: endOutput)
                    edge(.end, width: edgeWidth, height: height, startOutput: startOutput, endOutput: endOutput)
                        .offset(x: width - edgeWidth)
                }
                .frame(width: width, height: height, alignment: .topLeading)
                .offset(x: x, y: 4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(keyframe.source == .manual ? "Added" : "Auto") zoom, \(String(format: "%.1f", Double(keyframe.scale))) times")
                .accessibilityValue("\(Timecode.spoken(startOutput)) to \(Timecode.spoken(endOutput))")
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction {
                    editor.select(.zoom(keyframe.id))
                    editor.seek(toSource: keyframe.peakTime)
                }
                .accessibilityAdjustableAction { direction in
                    editor.select(.zoom(keyframe.id))
                    editor.moveSelectedKeyframe(by: direction == .increment ? 0.1 : -0.1)
                }
                .accessibilityAction(named: "Delete") {
                    editor.select(.zoom(keyframe.id))
                    editor.deleteSelectedKeyframe()
                }
            }
        }
    }

    private func edge(_ part: Part, width: CGFloat, height: CGFloat, startOutput: TimeInterval, endOutput: TimeInterval) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(dragGesture(part, startOutput: startOutput, endOutput: endOutput))
    }

    private func dragGesture(_ part: Part, startOutput: TimeInterval, endOutput: TimeInterval) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if drag == nil {
                    drag = (keyframe, startOutput, endOutput)
                    editor.select(.zoom(keyframe.id))
                    editor.beginInteractiveEdit(part == .body ? "Move Zoom" : "Resize Zoom")
                }
                guard let current = drag else { return }
                let snap = TimelineSnap(editor: editor, scale: scale, excluding: keyframe.id)
                let timeline = editor.timeline
                let delta = TimeInterval(value.translation.width / max(scale.pointsPerSecond, 0.01))
                let origin = current.origin
                let updated: ZoomKeyframe
                switch part {
                case .body:
                    let newStart = timeline.sourceTime(forOutput: snap(current.outputStart + delta))
                    updated = ZoomKeyframeEditor.moveKeyframe(origin, by: newStart - origin.startTime, duration: editor.duration)
                case .start:
                    let newStart = timeline.sourceTime(forOutput: snap(current.outputStart + delta))
                    updated = ZoomKeyframeEditor.resizeKeyframeStart(origin, to: newStart, duration: editor.duration)
                case .end:
                    let newEnd = timeline.sourceTime(forOutput: snap(current.outputEnd + delta))
                    updated = ZoomKeyframeEditor.resizeKeyframeEnd(origin, to: newEnd, duration: editor.duration)
                }
                editor.updateKeyframe(updated, commit: false, actionName: part == .body ? "Move Zoom" : "Resize Zoom")
            }
            .onEnded { _ in
                drag = nil
                editor.endInteractiveEdit()
            }
    }
}

// MARK: - Text and blur

private struct TimelineItem: Identifiable {
    let id: UUID
    let span: TimeSpan
    let title: String
    let selection: EditorSelection
}

private struct ItemTrack: View {
    enum Kind {
        case text
        case blur
    }

    @ObservedObject var editor: ProjectEditor
    let kind: Kind
    let scale: TimelineScale
    let visibleRange: ClosedRange<CGFloat>

    private var items: [TimelineItem] {
        switch kind {
        case .text:
            return editor.editSettings.textOverlays.map { overlay in
                let title = overlay.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return TimelineItem(id: overlay.id, span: overlay.span, title: title.isEmpty ? "Text" : title, selection: .text(overlay.id))
            }
        case .blur:
            return editor.editSettings.blurRegions.map { region in
                TimelineItem(id: region.id, span: region.span, title: region.kind.label, selection: .blur(region.id))
            }
        }
    }

    private var tint: Color {
        kind == .text ? DS.Palette.textTrack : DS.Palette.blurTrack
    }

    var body: some View {
        let list = items
        return ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { location in
                    editor.select(nil)
                    editor.seek(to: scale.time(for: location.x))
                }

            if list.isEmpty {
                Text(kind == .text ? "Press T to add text at the playhead" : "Press B to hide part of the screen")
                    .font(DS.Typeface.caption)
                    .foregroundStyle(DS.Palette.tertiaryText)
                    .padding(.leading, DS.Spacing.xs)
                    .frame(height: TimelineMetrics.itemHeight)
                    .offset(x: visibleRange.lowerBound)
                    .allowsHitTesting(false)
            }

            ForEach(list) { item in
                ItemBlock(editor: editor, item: item, tint: tint, scale: scale)
            }
        }
        .frame(width: max(scale.contentWidth, 1), height: TimelineMetrics.itemHeight, alignment: .topLeading)
    }
}

private struct ItemBlock: View {
    @ObservedObject var editor: ProjectEditor
    let item: TimelineItem
    let tint: Color
    let scale: TimelineScale

    @State private var drag: (origin: TimeSpan, outputStart: TimeInterval, outputEnd: TimeInterval)?

    private enum Part {
        case body
        case start
        case end
    }

    private var isSelected: Bool {
        editor.selection == item.selection
    }

    var body: some View {
        let timeline = editor.timeline
        let startOutput = timeline.outputTimeClamped(forSource: item.span.start)
        let endOutput = timeline.outputTimeClamped(forSource: item.span.end)
        let x = scale.x(for: startOutput)
        let width = scale.x(for: endOutput) - x
        let height = TimelineMetrics.itemHeight - 6
        let edgeWidth = min(8, max(width / 4, 2))

        return Group {
            if width >= 2 {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(tint.opacity(isSelected ? 0.5 : 0.28))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(isSelected ? tint : tint.opacity(0.7), lineWidth: isSelected ? 2 : 1)
                        )
                        .contentShape(Rectangle())
                        .gesture(dragGesture(.body, startOutput: startOutput, endOutput: endOutput))
                        .onTapGesture {
                            editor.select(item.selection)
                            editor.seek(toSource: item.span.start + min(0.3, item.span.duration / 2))
                        }

                    if width > 30 {
                        Text(item.title)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .foregroundStyle(Color.primary.opacity(0.85))
                            .padding(.horizontal, 6)
                            .frame(width: width, height: height, alignment: .leading)
                            .allowsHitTesting(false)
                    }

                    edge(.start, width: edgeWidth, height: height, startOutput: startOutput, endOutput: endOutput)
                    edge(.end, width: edgeWidth, height: height, startOutput: startOutput, endOutput: endOutput)
                        .offset(x: width - edgeWidth)
                }
                .frame(width: width, height: height, alignment: .topLeading)
                .offset(x: x, y: 3)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.title)
                .accessibilityValue("\(Timecode.spoken(startOutput)) to \(Timecode.spoken(endOutput))")
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction {
                    editor.select(item.selection)
                }
                .accessibilityAdjustableAction { direction in
                    editor.select(item.selection)
                    editor.nudgeSelection(by: direction == .increment ? 0.1 : -0.1)
                }
                .accessibilityAction(named: "Delete") {
                    editor.select(item.selection)
                    editor.deleteSelection()
                }
            }
        }
    }

    private func edge(_ part: Part, width: CGFloat, height: CGFloat, startOutput: TimeInterval, endOutput: TimeInterval) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(dragGesture(part, startOutput: startOutput, endOutput: endOutput))
    }

    private func dragGesture(_ part: Part, startOutput: TimeInterval, endOutput: TimeInterval) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if drag == nil {
                    drag = (item.span, startOutput, endOutput)
                    editor.select(item.selection)
                    editor.beginInteractiveEdit(part == .body ? "Move" : "Change Timing")
                }
                guard let current = drag else { return }
                let snap = TimelineSnap(editor: editor, scale: scale, excluding: item.id)
                let timeline = editor.timeline
                let delta = TimeInterval(value.translation.width / max(scale.pointsPerSecond, 0.01))
                let origin = current.origin
                let span: TimeSpan
                switch part {
                case .body:
                    let start = timeline.sourceTime(forOutput: snap(current.outputStart + delta))
                    span = TimeSpan(start: start, end: start + origin.duration)
                case .start:
                    let start = min(timeline.sourceTime(forOutput: snap(current.outputStart + delta)), origin.end - 0.1)
                    span = TimeSpan(start: start, end: origin.end)
                case .end:
                    let end = max(timeline.sourceTime(forOutput: snap(current.outputEnd + delta)), origin.start + 0.1)
                    span = TimeSpan(start: origin.start, end: end)
                }
                editor.setSpan(span, for: item.selection, continuous: true)
            }
            .onEnded { _ in
                drag = nil
                editor.endInteractiveEdit()
            }
    }
}

// MARK: - Audio

private struct WaveformTrack: View {
    @ObservedObject var editor: ProjectEditor
    @ObservedObject var media: TimelineMedia
    let scale: TimelineScale
    let visibleRange: ClosedRange<CGFloat>

    var body: some View {
        let start = visibleRange.lowerBound
        let width = visibleRange.upperBound - visibleRange.lowerBound
        let timeline = editor.timeline
        let peaks = media.peaks
        let end = scale.contentWidth
        return ZStack(alignment: .topLeading) {
            if media.isLoaded && peaks.isEmpty {
                Text("No audio")
                    .font(DS.Typeface.caption)
                    .foregroundStyle(DS.Palette.tertiaryText)
                    .padding(.leading, DS.Spacing.xs)
                    .frame(height: TimelineMetrics.audioHeight)
                    .offset(x: start)
            } else {
                Canvas { context, size in
                    let barWidth: CGFloat = 2
                    let gap: CGFloat = 1
                    let middle = size.height / 2
                    var x: CGFloat = 0
                    while x < size.width, start + x < end {
                        let from = timeline.sourceTime(forOutput: scale.time(for: start + x))
                        let to = timeline.sourceTime(forOutput: scale.time(for: start + x + barWidth + gap))
                        let level = Waveform.displayLevel(Waveform.peak(in: peaks, from: from, to: to))
                        let barHeight = max(1, level * (size.height - 6))
                        let bar = Path(roundedRect: CGRect(x: x, y: middle - barHeight / 2, width: barWidth, height: barHeight), cornerRadius: 1)
                        context.fill(bar, with: .color(DS.Palette.audioTrack.opacity(0.75)))
                        x += barWidth + gap
                    }
                }
                .frame(width: max(width, 1), height: TimelineMetrics.audioHeight)
                .offset(x: start)
            }
        }
        .frame(width: max(scale.contentWidth, 1), height: TimelineMetrics.audioHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { location in
            editor.seek(to: scale.time(for: location.x))
        }
        .accessibilityElement()
        .accessibilityLabel(peaks.isEmpty ? "No audio" : "Audio waveform")
    }
}
