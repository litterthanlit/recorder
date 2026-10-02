import SwiftUI

/// The entry point. `Trace --mcp` serves AI agents over stdin/stdout without any UI (see
/// `MCPStdioServer`); anything else starts the app.
@main
enum TraceMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.dropFirst().contains(MCPStdioServer.argument) {
            MCPStdioServer.run()
        }
        RecorderApp.main()
    }
}
