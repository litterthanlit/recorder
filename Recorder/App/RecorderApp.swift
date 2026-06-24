import SwiftUI

@main
struct RecorderApp: App {
    @StateObject private var session = RecordingSession()
    @StateObject private var permissions = PermissionsManager.shared

    var body: some Scene {
        MenuBarExtra("Recorder", systemImage: "record.circle") {
            MenuBarView(session: session, permissions: permissions)
        }
        .menuBarExtraStyle(.window)

        WindowGroup(id: "editor", for: UUID.self) { $projectID in
            if let projectID, let editor = session.editor(for: projectID) {
                EditorView(editor: editor)
                    .onChange(of: editor.state) { newState in
                        if case .exported = newState {
                            session.markExported(editor.project)
                        }
                    }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "film")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Recording Not Found")
                        .font(.headline)
                    Text("Stop a recording to open the editor.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .defaultSize(width: 820, height: 680)
    }
}
