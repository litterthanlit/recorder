import Foundation

enum ExportNaming {
    /// Suggested file name for an exported take, from when it was recorded, in the style of
    /// macOS screenshots: "Recorder 2026-09-30 at 14.32.mp4". Dots rather than colons,
    /// which Finder shows as slashes.
    static func defaultFileName(recordedAt date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let stamp = String(
            format: "%04d-%02d-%02d at %02d.%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0
        )
        return "Recorder \(stamp).mp4"
    }
}
