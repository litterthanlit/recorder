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
        .frame(minWidth: 760, minHeight: 640)
        .onChange(of: editor.editSettings) { _ in
            editor.persistEditSettings()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Edit Recording")
                    .font(.title2.weight(.semibold))
                Text("Trim, tune zooms, and export a launch-ready 1080p MP4")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") {
                dismiss()
            }
        }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    editor.isManualZoomMode.toggle()
                    if editor.isManualZoomMode {
                        editor.player.pause()
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
                .disabled(editor.selectedKeyframeID == nil)

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
                        in: 1.2...2.5
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
                Picker("Resolution", selection: $editor.editSettings.exportPreset) {
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

            Toggle("Dark background frame", isOn: $editor.editSettings.exportStyle.backgroundEnabled)
            Toggle("Cursor smoothing", isOn: $editor.editSettings.exportStyle.cursorSmoothingEnabled)
            Toggle("Watermark", isOn: $editor.editSettings.exportStyle.watermarkEnabled)

            if editor.editSettings.exportStyle.watermarkEnabled {
                TextField("Watermark", text: $editor.editSettings.exportStyle.watermarkText)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var exportSection: some View {
        switch editor.state {
        case .editing:
            Button {
                Task { await editor.export() }
            } label: {
                Label("Export MP4", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

        case let .exporting(progress):
            VStack(alignment: .leading, spacing: 8) {
                Label("Exporting…", systemImage: "film")
                ProgressView(value: progress)
            }

        case .exported:
            HStack {
                Label("Export complete", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button("Show in Finder") {
                    editor.revealExportInFinder()
                }
                .buttonStyle(.bordered)
            }

        case let .failed(message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.caption)
        }
    }
}
