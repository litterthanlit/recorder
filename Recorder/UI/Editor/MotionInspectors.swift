import SwiftUI

/// The transition picker's choices: straight cuts, or a transition style.
private enum TransitionChoice: Hashable {
    case straight
    case style(CutTransitionStyle)

    static var all: [TransitionChoice] {
        [TransitionChoice.straight] + CutTransitionStyle.allCases.map { TransitionChoice.style($0) }
    }

    var label: String {
        switch self {
        case .straight: return "None"
        case let .style(style): return style.label
        }
    }
}

/// Inspector › Zoom › Cuts and speed: a transition at every cut, and easing into and
/// out of sped-up parts.
struct CutMotionSection: View {
    @ObservedObject var editor: ProjectEditor

    private var transition: Binding<CutTransition?> {
        editor.settingBinding(\.cutTransition, actionName: "Cut Transition")
    }

    private var choice: Binding<TransitionChoice> {
        let transition = self.transition
        return Binding(
            get: { transition.wrappedValue.map { TransitionChoice.style($0.style) } ?? TransitionChoice.straight },
            set: { newChoice in
                switch newChoice {
                case .straight:
                    transition.wrappedValue = nil
                case let .style(style):
                    var updated = transition.wrappedValue ?? CutTransition()
                    updated.style = style
                    transition.wrappedValue = updated
                }
            }
        )
    }

    private var length: Binding<Double> {
        let transition = editor.settingBinding(\.cutTransition, actionName: "Transition Length", continuous: true)
        return Binding(
            get: { transition.wrappedValue?.duration ?? CutTransition().duration },
            set: { value in
                var updated = transition.wrappedValue ?? CutTransition()
                updated.duration = min(max(value, CutTransition.durationRange.lowerBound), CutTransition.durationRange.upperBound)
                transition.wrappedValue = updated
            }
        )
    }

    private var smoothSpeed: Binding<Bool> {
        Binding(
            get: { editor.smoothSpeedChanges },
            set: { editor.setSmoothSpeedChanges($0) }
        )
    }

    var body: some View {
        InspectorSection("Cuts and speed") {
            InspectorLabeled("Transition") {
                InspectorSegmentedPicker("Transition", selection: choice, options: TransitionChoice.all) { $0.label }
                InspectorHint("Plays at every cut, where the edit skips part of the recording.")
            }
            if editor.editSettings.cutTransition != nil {
                EditorSlider(
                    editor: editor,
                    title: "Length",
                    actionName: "Transition Length",
                    value: length,
                    range: CutTransition.durationRange
                ) { String(format: "%.2f s", $0) }
            }
            InspectorToggle(
                title: "Smooth speed changes",
                subtitle: "Eases into and out of sped-up clips instead of jumping.",
                isOn: smoothSpeed
            )
        }
    }
}

/// Inspector › Audio › Cuts and speed: fades at cuts, and silence over fast parts.
struct CutAudioSection: View {
    @ObservedObject var editor: ProjectEditor

    var body: some View {
        InspectorSection("Cuts and speed") {
            InspectorToggle(
                title: "Fade at cuts",
                subtitle: "A short fade either side of each cut, so it doesn't click.",
                isOn: editor.settingBinding(\.audio.cutFades, actionName: "Fade at Cuts")
            )
            InspectorToggle(
                title: "Mute fast parts",
                subtitle: "Silences clips played faster than 2.5×.",
                isOn: editor.settingBinding(\.audio.muteSpedUp, actionName: "Mute Fast Parts")
            )
        }
    }
}

/// Inspector › Zoom › 3D moves: add a move at the playhead.
struct CameraMovesSection: View {
    @ObservedObject var editor: ProjectEditor

    private var summary: String {
        let count = editor.editSettings.cameraMoves.count
        let onTrack = count == 0 ? "None yet." : "\(count) on the 3D track."
        return "\(onTrack) Tilt In opens a video, Tilt Out closes one; Float and Orbit bring a still screen to life."
    }

    var body: some View {
        InspectorSection("3D moves") {
            Menu {
                ForEach(CameraMoveKind.allCases) { kind in
                    Button(kind.label) {
                        editor.addCameraMove(kind)
                    }
                }
            } label: {
                Label("Add at Playhead", systemImage: "rotate.3d")
            }
            .fixedSize()
            .accessibilityLabel("Add a 3D move at the playhead")
            InspectorHint(summary)
        }
    }
}
