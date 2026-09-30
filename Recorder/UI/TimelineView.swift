import AppKit
import SwiftUI

/// Heights of the timeline's rows.
enum TimelineMetrics {
    static let headerWidth: CGFloat = 96
    static let rulerHeight: CGFloat = 26
    static let clipHeight: CGFloat = 58
    static let zoomHeight: CGFloat = 32
    static let itemHeight: CGFloat = 28
    static let audioHeight: CGFloat = 40
    /// Room after the end of the edit, so the last clip's edge can be grabbed.
    static let trailingSpace: CGFloat = 40

    static var tracksHeight: CGFloat {
        clipHeight + zoomHeight + itemHeight * 2 + audioHeight
    }

    static var preferredHeight: CGFloat {
        rulerHeight + tracksHeight + 12
    }
}

/// How far the timeline is zoomed in: 1 shows the whole recording.
final class TimelineZoom: ObservableObject {
    @Published var factor: CGFloat = 1

    static let range: ClosedRange<CGFloat> = 1...64

    func zoomIn() {
        factor = min(factor * 1.5, Self.range.upperBound)
    }

    func zoomOut() {
        factor = max(factor / 1.5, Self.range.lowerBound)
    }

    func fit() {
        factor = Self.range.lowerBound
    }
}

private struct TimelineScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// The edited video laid out in output time: clips (with thumbnails and speed), zooms,
/// text, blur and audio, under a ruler you can scrub. Everything is drawn at its place
/// in the edit, so what's cut away doesn't show.
struct TimelineView: View {
    @ObservedObject var editor: ProjectEditor
    let playback: EditorPlayback
    @ObservedObject var zoom: TimelineZoom
    @StateObject private var media = TimelineMedia()
    @State private var scrollOffset: CGFloat = 0
    @State private var pinchStart: CGFloat?

    private static let scrollSpace = "timeline.scroll"

    var body: some View {
        HStack(spacing: 0) {
            TimelineTrackHeaders()
                .frame(width: TimelineMetrics.headerWidth)
            Divider()
            GeometryReader { geometry in
                scrollArea(viewport: geometry.size.width)
            }
        }
        .background(DS.Palette.surface)
        .task(id: editor.project.metadata.id) {
            await media.load(project: editor.project)
        }
    }

    /// Points per second. The fit is based on the recording's length rather than the
    /// edit's, so cutting or trimming doesn't rescale everything under the pointer.
    private func scale(viewport: CGFloat) -> TimelineScale {
        let fit = TimelineScale.fitting(
            duration: max(editor.duration, 0.1),
            width: max(viewport - TimelineMetrics.trailingSpace, 50)
        )
        return TimelineScale(pointsPerSecond: fit.pointsPerSecond * zoom.factor, duration: editor.outputDuration)
    }

    private func scrollArea(viewport: CGFloat) -> some View {
        let scale = scale(viewport: viewport)
        let contentWidth = max(scale.contentWidth + TimelineMetrics.trailingSpace, viewport)
        let visible = max(0, scrollOffset)...max(0, scrollOffset) + viewport
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                TimelineContent(
                    editor: editor,
                    playback: playback,
                    media: media,
                    scale: scale,
                    visibleRange: visible
                )
                .frame(width: contentWidth, alignment: .leading)
                .background(
                    GeometryReader { content in
                        Color.clear.preference(
                            key: TimelineScrollOffsetKey.self,
                            value: -content.frame(in: .named(Self.scrollSpace)).minX
                        )
                    }
                )
            }
            .coordinateSpace(name: Self.scrollSpace)
            .onPreferenceChange(TimelineScrollOffsetKey.self) { offset in
                Task { @MainActor in
                    scrollOffset = offset
                }
            }
            .background(
                PlayheadFollower(
                    playback: playback,
                    scale: scale,
                    offset: scrollOffset,
                    viewport: viewport,
                    proxy: proxy
                )
            )
            .onChange(of: zoom.factor) { _, _ in
                // Keep the playhead in view when zooming.
                proxy.scrollTo(PlayheadLine.anchorID, anchor: .center)
            }
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        let start = pinchStart ?? zoom.factor
                        pinchStart = start
                        zoom.factor = min(max(start * value.magnification, TimelineZoom.range.lowerBound), TimelineZoom.range.upperBound)
                    }
                    .onEnded { _ in pinchStart = nil }
            )
        }
    }
}

/// Scrolls the timeline to keep the playhead in view while playing.
private struct PlayheadFollower: View {
    @ObservedObject var playback: EditorPlayback
    let scale: TimelineScale
    let offset: CGFloat
    let viewport: CGFloat
    let proxy: ScrollViewProxy

    var body: some View {
        Color.clear
            .onChange(of: playback.time) { _, time in
                guard playback.isPlaying else { return }
                let x = scale.x(for: time)
                if x < offset || x > offset + viewport - 24 {
                    proxy.scrollTo(PlayheadLine.anchorID, anchor: UnitPoint(x: 0.08, y: 0.5))
                }
            }
    }
}

/// Track names down the left side, lined up with the tracks.
private struct TimelineTrackHeaders: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: TimelineMetrics.rulerHeight)
            header("Clips", icon: "film", tint: DS.Palette.clipTrack, height: TimelineMetrics.clipHeight)
            header("Zoom", icon: "plus.magnifyingglass", tint: DS.Palette.zoomTrack, height: TimelineMetrics.zoomHeight)
            header("Text", icon: "textformat", tint: DS.Palette.textTrack, height: TimelineMetrics.itemHeight)
            header("Blur", icon: "eye.slash", tint: DS.Palette.blurTrack, height: TimelineMetrics.itemHeight)
            header("Audio", icon: "waveform", tint: DS.Palette.audioTrack, height: TimelineMetrics.audioHeight)
            Spacer(minLength: 0)
        }
        .accessibilityHidden(true)
    }

    private func header(_ title: String, icon: String, tint: Color, height: CGFloat) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 14)
            Text(title)
                .font(DS.Typeface.footnote.weight(.medium))
                .foregroundStyle(DS.Palette.secondaryText)
        }
        .padding(.leading, DS.Spacing.sm)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DS.Palette.separator.opacity(0.5))
                .frame(height: 0.5)
        }
    }
}
