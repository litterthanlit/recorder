import AppKit
import SwiftUI

/// Settings for what's selected on the timeline.
struct SelectionInspector: View {
    @ObservedObject var editor: ProjectEditor

    var body: some View {
        switch editor.selection {
        case .clip(let id)?:
            if let index = editor.timeline.segments.firstIndex(where: { $0.id == id }) {
                ClipInspector(editor: editor, segment: editor.timeline.segments[index], index: index)
            }
        case .zoom?:
            if let keyframe = editor.selectedKeyframe {
                ZoomSelectionInspector(editor: editor, keyframe: keyframe)
            }
        case .text?:
            if let overlay = editor.selectedText {
                TextInspector(editor: editor, overlay: overlay)
            }
        case .blur?:
            if let region = editor.selectedBlur {
                BlurInspector(editor: editor, region: region)
            }
        case nil:
            EmptyView()
        }
    }
}

private struct ClipInspector: View {
    @ObservedObject var editor: ProjectEditor
    let segment: EditSegment
    let index: Int

    static let speeds: [Double] = [0.5, 1, 1.5, 2, 4, 8]

    private var speedBinding: Binding<Double> {
        let id = segment.id
        return Binding(
            get: { segment.speed },
            set: { editor.setSpeed($0, forSegment: id) }
        )
    }

    /// The slider moves in doublings, so 1× sits in the middle of 0.25×–16×.
    private var logSpeedBinding: Binding<Double> {
        let id = segment.id
        return Binding(
            get: { log2(segment.speed) },
            set: { editor.setSpeed(pow(2, $0), forSegment: id) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            InspectorSection("Clip \(index + 1) of \(editor.timeline.segments.count)") {
                Text("\(Timecode.precise(segment.source.duration)) of recording, plays in \(Timecode.precise(segment.outputDuration))")
                    .font(DS.Typeface.body)
            }
            InspectorSection("Speed") {
                Picker("Speed", selection: speedBinding) {
                    ForEach(Self.speeds, id: \.self) { speed in
                        Text(Timecode.speed(speed)).tag(speed)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                EditorSlider(
                    editor: editor,
                    title: "Custom",
                    actionName: "Change Speed",
                    value: logSpeedBinding,
                    range: log2(EditTimeline.speedRange.lowerBound)...log2(EditTimeline.speedRange.upperBound)
                ) { Timecode.speed((pow(2, $0) * 100).rounded() / 100) }
                InspectorHint("Sped-up audio keeps its pitch.")
            }
            InspectorSection("Edit") {
                HStack(spacing: DS.Spacing.xs) {
                    Button {
                        editor.splitAtPlayhead()
                    } label: {
                        Label("Split at Playhead", systemImage: "scissors")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("Split at the playhead (S)")
                    Button {
                        if editor.speedUpIdleStretches() == 0 {
                            NSSound.beep()
                        }
                    } label: {
                        Label("Speed Up Idle", systemImage: "hare")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("Play stretches with no clicks, pointer movement or typing at 4×")
                }
                InspectorDeleteButton(title: "Delete Clip") {
                    editor.deleteSegment(segment.id)
                }
                .disabled(editor.timeline.segments.count < 2)
            }
        }
    }
}

private struct ZoomSelectionInspector: View {
    @ObservedObject var editor: ProjectEditor
    let keyframe: ZoomKeyframe

    private var scaleBinding: Binding<Double> {
        Binding(
            get: { Double(keyframe.scale) },
            set: { editor.updateSelectedKeyframeScale(CGFloat($0)) }
        )
    }

    private var outputStart: TimeInterval { editor.timeline.outputTimeClamped(forSource: keyframe.startTime) }
    private var outputEnd: TimeInterval { editor.timeline.outputTimeClamped(forSource: keyframe.endTime) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            InspectorSection(keyframe.source == .manual ? "Zoom (added)" : "Zoom (auto)") {
                EditorSlider(
                    editor: editor,
                    title: "Zoom",
                    actionName: "Zoom Scale",
                    value: scaleBinding,
                    range: Double(ZoomKeyframeEditor.focusScaleRange.lowerBound)...Double(ZoomKeyframeEditor.focusScaleRange.upperBound)
                ) { String(format: "%.1f×", $0) }
                Button {
                    toggleFocusEditing()
                } label: {
                    Label(editor.isEditingZoomFocus ? "Done Adjusting" : "Adjust Focus", systemImage: "scope")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                InspectorHint("Drag the frame on the preview to choose where the zoom points; drag a corner to zoom closer or wider.")
                Text("\(Timecode.precise(outputStart)) – \(Timecode.precise(outputEnd))")
                    .font(DS.Typeface.caption.monospacedDigit())
                    .foregroundStyle(DS.Palette.secondaryText)
                    .accessibilityLabel("From \(Timecode.spoken(outputStart)) to \(Timecode.spoken(outputEnd))")
            }
            InspectorDeleteButton(title: "Delete Zoom") {
                editor.deleteSelectedKeyframe()
            }
        }
    }

    private func toggleFocusEditing() {
        if editor.isEditingZoomFocus {
            editor.isEditingZoomFocus = false
        } else {
            editor.pausePlayback()
            editor.seek(toSource: keyframe.peakTime)
            editor.isEditingZoomFocus = true
        }
    }
}

private struct TextInspector: View {
    @ObservedObject var editor: ProjectEditor
    let overlay: TextOverlay

    private var textBinding: Binding<String> {
        let id = overlay.id
        return Binding(
            get: { overlay.text },
            set: { value in editor.updateText(id, actionName: "Edit Text", coalesce: true) { $0.text = value } }
        )
    }

    private var styleBinding: Binding<TextOverlay.Style> {
        let id = overlay.id
        return Binding(
            get: { overlay.style },
            set: { value in editor.updateText(id, actionName: "Text Style") { $0.style = value } }
        )
    }

    private var scaleBinding: Binding<Double> {
        let id = overlay.id
        return Binding(
            get: { overlay.scale },
            set: { value in editor.updateText(id, actionName: "Text Size", coalesce: true, continuous: true) { $0.scale = value } }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            InspectorSection("Text") {
                TextField("Text", text: textBinding, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Text")
                InspectorLabeled("Style") {
                    Picker("Style", selection: styleBinding) {
                        ForEach(TextOverlay.Style.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                EditorSlider(
                    editor: editor,
                    title: "Size",
                    actionName: "Text Size",
                    value: scaleBinding,
                    range: 0.5...2
                ) { "\(Int(($0 * 100).rounded()))%" }
                InspectorHint("Drag the text on the preview to move it. Drag its ends on the Text track to change when it shows.")
            }
            InspectorDeleteButton(title: "Delete Text") {
                editor.deleteText(overlay.id)
            }
        }
    }
}

private struct BlurInspector: View {
    @ObservedObject var editor: ProjectEditor
    let region: BlurRegion

    private var kindBinding: Binding<BlurRegion.Kind> {
        let id = region.id
        return Binding(
            get: { region.kind },
            set: { value in editor.updateBlur(id, actionName: "Blur Style") { $0.kind = value } }
        )
    }

    private var strengthBinding: Binding<Double> {
        let id = region.id
        return Binding(
            get: { region.strength },
            set: { value in editor.updateBlur(id, actionName: "Blur Strength", coalesce: true, continuous: true) { $0.strength = value } }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            InspectorSection("Hide") {
                Picker("Style", selection: kindBinding) {
                    ForEach(BlurRegion.Kind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                EditorSlider(
                    editor: editor,
                    title: "Strength",
                    actionName: "Blur Strength",
                    value: strengthBinding,
                    range: 0...1
                ) { "\(Int(($0 * 100).rounded()))%" }
                InspectorHint("Drag the box on the preview over what to hide, and its corners to resize it. It follows zooms.")
            }
            InspectorDeleteButton(title: "Delete Blur") {
                editor.deleteBlur(region.id)
            }
        }
    }
}
