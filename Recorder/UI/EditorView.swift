import AppKit
import SwiftUI

/// The editor window's content: the canvas with its transport bar, the inspector on the
/// right, and the timeline along the bottom. The name, shape, undo, Retake and Export
/// live in the window's toolbar (`EditorToolbarController`).
struct EditorView: View {
    @ObservedObject var editor: ProjectEditor
    let actions: EditorActions
    @StateObject private var timelineZoom = TimelineZoom()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    EditorPreviewView(editor: editor)
                    Divider()
                    TransportBar(
                        editor: editor,
                        playback: editor.playback,
                        timelineZoom: timelineZoom,
                        onAddZoom: toggleManualZoom
                    )
                }
                Divider()
                InspectorView(editor: editor)
            }
            Divider()
            TimelineView(editor: editor, playback: editor.playback, zoom: timelineZoom)
                .frame(height: TimelineMetrics.preferredHeight)
        }
        .frame(minWidth: 1040, minHeight: 700)
        .background(EditorKeyCommands(handler: perform))
    }

    private func toggleManualZoom() {
        editor.pausePlayback()
        editor.isEditingZoomFocus = false
        editor.isManualZoomMode.toggle()
    }

    /// Carries out a keyboard shortcut; returns whether it applied.
    private func perform(_ command: EditorCommand) -> Bool {
        switch command {
        case .togglePlayback:
            editor.togglePlayback()
        case let .stepFrames(frames):
            editor.step(frames: frames)
        case let .stepSeconds(seconds):
            editor.step(seconds: seconds)
        case .goToStart:
            editor.seek(to: 0)
        case .goToEnd:
            editor.seek(to: editor.outputDuration)
        case .split:
            editor.splitAtPlayhead()
        case .deleteSelection:
            guard editor.selection != nil else { return false }
            editor.deleteSelection()
        case .addZoom:
            toggleManualZoom()
        case .addText:
            editor.addText()
        case .addBlur:
            editor.addBlur()
        case .export:
            actions.export()
        case .timelineZoomIn:
            timelineZoom.zoomIn()
        case .timelineZoomOut:
            timelineZoom.zoomOut()
        case .timelineZoomToFit:
            timelineZoom.fit()
        case let .nudgeSelection(delta):
            guard editor.selection != nil else { return false }
            editor.nudgeSelection(by: delta)
        case .clearSelection:
            if editor.isManualZoomMode {
                editor.isManualZoomMode = false
            } else if editor.isEditingZoomFocus {
                editor.isEditingZoomFocus = false
            } else if editor.selection != nil {
                editor.select(nil)
            } else {
                return false
            }
        case .undo:
            guard editor.canUndo else { return false }
            editor.undo()
        case .redo:
            guard editor.canRedo else { return false }
            editor.redo()
        }
        return true
    }
}
