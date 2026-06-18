import SwiftUI

struct EditorView: View {
    @ObservedObject var editor: ProjectEditor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            EditorPreviewView(editor: editor)
            TimelineView(editor: editor)
            toolbar
            exportSection
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 560)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Edit Recording")
                    .font(.title2.weight(.semibold))
                Text("Adjust zoom timing or add manual zoom regions")
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
