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
    }
}
