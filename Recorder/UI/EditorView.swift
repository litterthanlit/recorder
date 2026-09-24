import AppKit
import SwiftUI

struct EditorView: View {
    @ObservedObject var editor: ProjectEditor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                EditorPreviewView(editor: editor)
                TimelineView(editor: editor)
                toolbar
                exportSettingsSection
                exportSection
            }
            .padding(20)
        }
        .frame(minWidth: 960, minHeight: 760)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Edit Recording")
                    .font(.title2.weight(.semibold))
                Text("Preview matches export — spring camera, click ripples, then export")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            HStack(spacing: 6) {
                Button {
                    editor.undo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!editor.canUndo)
                .help(editor.undoActionName.map { "Undo \($0) (⌘Z)" } ?? "Nothing to undo")
                .accessibilityLabel(editor.undoActionName.map { "Undo \($0)" } ?? "Undo")

                Button {
                    editor.redo()
                } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!editor.canRedo)
                .help(editor.redoActionName.map { "Redo \($0) (⇧⌘Z)" } ?? "Nothing to redo")
                .accessibilityLabel(editor.redoActionName.map { "Redo \($0)" } ?? "Redo")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)

            Button("Close") {
                dismiss()
                NSApp.keyWindow?.close()
            }
            .padding(.leading, 8)
        }
    }

    /// ⌥← / ⌥→ move the selected zoom by 0.1 s, with ⇧ by 1 s. Option keeps plain
    /// arrows for sliders and pickers.
    private var nudgeButtons: some View {
        HStack(spacing: 4) {
            nudgeButton(-1, key: .leftArrow, modifiers: [.option, .shift])
            nudgeButton(-0.1, key: .leftArrow, modifiers: .option)
            nudgeButton(0.1, key: .rightArrow, modifiers: .option)
            nudgeButton(1, key: .rightArrow, modifiers: [.option, .shift])
        }
        .buttonStyle(.bordered)
        .disabled(editor.selectedKeyframeID == nil)
    }

    private func nudgeButton(_ delta: TimeInterval, key: KeyEquivalent, modifiers: EventModifiers) -> some View {
        let isLarge = abs(delta) >= 1
        let direction = delta < 0 ? "earlier" : "later"
        let symbol = delta < 0
            ? (isLarge ? "backward.end" : "chevron.backward")
            : (isLarge ? "forward.end" : "chevron.forward")
        let shortcut = (isLarge ? "⇧" : "") + "⌥" + (delta < 0 ? "←" : "→")
        return Button {
            editor.moveSelectedKeyframe(by: delta)
        } label: {
            Image(systemName: symbol)
        }
        .keyboardShortcut(key, modifiers: modifiers)
        .help("Move the selected zoom \(isLarge ? "1 s" : "0.1 s") \(direction) (\(shortcut))")
        .accessibilityLabel("Move zoom \(isLarge ? "1 second" : "a tenth of a second") \(direction)")
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    editor.isManualZoomMode.toggle()
                    if editor.isManualZoomMode {
                        editor.pausePlayback()
                    }
                } label: {
                    Label(
                        editor.isManualZoomMode ? "Cancel Manual Zoom" : "Add Manual Zoom",
                        systemImage: "viewfinder"
                    )
                }
                .buttonStyle(.bordered)
                .tint(editor.isManualZoomMode ? .orange : .accentColor)

                Button(role: .destructive) {
                    editor.deleteSelectedKeyframe()
                } label: {
                    Label("Delete Selected", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.delete, modifiers: .command)
                .help("Delete the selected zoom (⌘⌫)")
                .disabled(editor.selectedKeyframeID == nil)

                nudgeButtons

                Spacer()

                if let selectedID = editor.selectedKeyframeID,
                   let keyframe = editor.keyframes.first(where: { $0.id == selectedID }) {
                    Text(keyframe.source == .manual ? "Manual zoom" : "Auto zoom")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                }
            }

            HStack(spacing: 12) {
                Text("Zoom preset")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Zoom preset", selection: Binding(
                    get: { editor.editSettings.zoomPreset },
                    set: { editor.applyZoomPreset($0) }
                )) {
                    ForEach(ZoomPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)

                if editor.selectedKeyframeID != nil {
                    Slider(
                        value: Binding(
                            get: {
                                editor.keyframes.first(where: { $0.id == editor.selectedKeyframeID })?.scale ?? 1.6
                            },
                            set: { editor.updateSelectedKeyframeScale($0) }
                        ),
                        in: 1.2...2.5,
                        onEditingChanged: { isEditing in
                            // One undo step per slider drag.
                            if isEditing {
                                editor.beginInteractiveEdit("Zoom Scale")
                            } else {
                                editor.endInteractiveEdit()
                            }
                        }
                    )
                    .frame(maxWidth: 160)

                    Text("Scale")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var exportSettingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Export")
                .font(.headline)

            HStack(spacing: 12) {
                Picker("Resolution", selection: editor.settingBinding(\.exportPreset, actionName: "Change Resolution")) {
                    ForEach(ExportResolutionPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)

                Text("\(Int(editor.exportOutputSize.width))×\(Int(editor.exportOutputSize.height))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Toggle("Dark background frame", isOn: editor.settingBinding(\.exportStyle.backgroundEnabled, actionName: "Background Frame"))
            Toggle("Spring camera", isOn: editor.settingBinding(\.exportStyle.springCameraEnabled, actionName: "Spring Camera"))
            Toggle("Click ripples", isOn: editor.settingBinding(\.exportStyle.clickRipplesEnabled, actionName: "Click Ripples"))
            Toggle("Cursor smoothing", isOn: editor.settingBinding(\.exportStyle.cursorSmoothingEnabled, actionName: "Cursor Smoothing"))
            Toggle("Cursor click scale", isOn: editor.settingBinding(\.exportStyle.cursorScaleOnClickEnabled, actionName: "Cursor Click Scale"))
            Toggle("Cursor spotlight", isOn: editor.settingBinding(\.exportStyle.cursorSpotlightEnabled, actionName: "Cursor Spotlight"))
            Toggle("Watermark", isOn: editor.settingBinding(\.exportStyle.watermarkEnabled, actionName: "Watermark"))

            if editor.editSettings.exportStyle.watermarkEnabled {
                TextField("Watermark", text: editor.settingBinding(\.exportStyle.watermarkText, actionName: "Watermark Text", coalesce: true))
                    .textFieldStyle(.roundedBorder)
            }

            if editor.hasCameraTrack {
                Divider()

                Toggle("Camera bubble", isOn: editor.settingBinding(\.camera.isVisible, actionName: "Camera Bubble"))

                if editor.editSettings.camera.isVisible {
                    Picker("Camera position", selection: editor.settingBinding(\.camera.position, actionName: "Camera Position")) {
                        ForEach(CameraBubblePosition.allCases) { position in
                            Text(position.label).tag(position)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 420)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var exportSection: some View {
        switch editor.state {
        case .editing:
            exportButton(title: "Export MP4")

        case let .exporting(progress):
            VStack(alignment: .leading, spacing: 8) {
                Label("Exporting…", systemImage: "film")
                ProgressView(value: progress)
            }

        case .exported:
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Export complete", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Show in Finder") {
                        editor.revealExportInFinder()
                    }
                    .buttonStyle(.bordered)
                }
                exportButton(title: "Export Again")
            }

        case let .failed(message):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                exportButton(title: "Retry Export")
            }
        }
    }

    private func exportButton(title: String) -> some View {
        Button {
            Task { await editor.export() }
        } label: {
            Label(title, systemImage: "square.and.arrow.up")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}
