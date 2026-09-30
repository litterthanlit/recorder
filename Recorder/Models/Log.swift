import os

/// Unified logging, one category per area. Read with Console.app or
/// `log stream --predicate 'subsystem == "app.hypher.recorder"'`.
enum Log {
    private static let subsystem = "app.hypher.recorder"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let editor = Logger(subsystem: subsystem, category: "editor")
    static let export = Logger(subsystem: subsystem, category: "export")
    static let library = Logger(subsystem: subsystem, category: "library")
    static let hotkeys = Logger(subsystem: subsystem, category: "hotkeys")
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
}
