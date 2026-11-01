import AppKit
import SwiftUI

/// Under the canvas: play, the timecode, the tools that add things at the playhead,
/// and timeline zoom.
struct TransportBar: View {
    @ObservedObject var editor: ProjectEditor
    @ObservedObject var playback: EditorPlayback
    @ObservedObject var timelineZoom: TimelineZoom
    let onAddZoom: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            playButton
            timecode
            Spacer(minLength: DS.Spacing.sm)
            tools
            Spacer(minLength: DS.Spacing.sm)
            zoomControls
        }
        .padding(.horizontal, DS.Spacing.sm)
        .frame(height: 44)
        .background(DS.Palette.surface)
    }

    private var playButton: some View {
        Button {
            editor.togglePlayback()
        } label: {
            Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.primary)
        }
        .buttonStyle(IconButtonStyle(size: 32))
        .help(playback.isPlaying ? "Pause (Space)" : "Play (Space)")
        .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
    }

    private var timecode: some View {
        HStack(spacing: 4) {
            Text(Timecode.precise(playback.time))
                .foregroundStyle(Color.primary)
            Text("/")
                .foregroundStyle(DS.Palette.tertiaryText)
            Text(Timecode.precise(editor.outputDuration))
                .foregroundStyle(DS.Palette.secondaryText)
        }
        .font(DS.Typeface.timecode)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Timecode.spoken(playback.time)) of \(Timecode.spoken(editor.outputDuration))")
    }

    private var tools: some View {
        HStack(spacing: DS.Spacing.xxs) {
            TransportTool(title: "Split", icon: "scissors", shortcut: "S", help: "Split the clip at the playhead") {
                editor.splitAtPlayhead()
            }
            TransportTool(title: "Zoom", icon: "plus.magnifyingglass", shortcut: "Z", help: "Drag over the preview to zoom in there", isActive: editor.isManualZoomMode) {
                onAddZoom()
            }
            TransportTool(title: "Text", icon: "textformat", shortcut: "T", help: "Add a caption at the playhead") {
                editor.addText()
            }
            TransportTool(title: "Blur", icon: "eye.slash", shortcut: "B", help: "Hide part of the screen from the playhead on") {
                editor.addBlur()
            }
        }
    }

    private var zoomSliderBinding: Binding<Double> {
        Binding(
            get: { log2(Double(timelineZoom.factor)) },
            set: { timelineZoom.factor = CGFloat(pow(2, $0)) }
        )
    }

    private var zoomControls: some View {
        HStack(spacing: 2) {
            Button {
                timelineZoom.zoomOut()
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(IconButtonStyle())
            .disabled(timelineZoom.factor <= TimelineZoom.range.lowerBound)
            .help("Zoom out the timeline (⌘−)")
            .accessibilityLabel("Zoom out timeline")

            Slider(value: zoomSliderBinding, in: 0...log2(Double(TimelineZoom.range.upperBound)))
                .controlSize(.mini)
                .frame(width: 84)
                .accessibilityLabel("Timeline zoom")

            Button {
                timelineZoom.zoomIn()
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(IconButtonStyle())
            .disabled(timelineZoom.factor >= TimelineZoom.range.upperBound)
            .help("Zoom in the timeline (⌘+)")
            .accessibilityLabel("Zoom in timeline")
        }
    }
}

private struct TransportTool: View {
    let title: String
    let icon: String
    let shortcut: String
    let help: String
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .labelStyle(.titleAndIcon)
                .font(DS.Typeface.footnote.weight(.medium))
                .foregroundStyle(isActive ? DS.Palette.accent : Color.primary)
        }
        .buttonStyle(SecondaryButtonStyle())
        .help("\(help) (\(shortcut))")
        .accessibilityHint("Shortcut \(shortcut)")
    }
}
