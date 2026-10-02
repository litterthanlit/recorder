import CoreGraphics
import Foundation

/// Which app was in front at a moment of a take, and where its front window sat in the
/// recording. Window titles are left out: they can say private things.
struct AppFocusEvent: Codable, Equatable {
    /// Source seconds.
    var timestamp: TimeInterval
    var bundleID: String?
    var appName: String
    /// The app's front window in the recording: normalized, bottom-left origin, clipped
    /// to the recording; `nil` when it isn't in the recording.
    var windowRect: CGRect?

    init(timestamp: TimeInterval, bundleID: String?, appName: String, windowRect: CGRect?) {
        self.timestamp = timestamp
        self.bundleID = bundleID
        self.appName = appName
        self.windowRect = windowRect
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(TimeInterval.self, forKey: .timestamp)
        bundleID = try? container.decodeIfPresent(String.self, forKey: .bundleID)
        appName = (try? container.decodeIfPresent(String.self, forKey: .appName)) ?? "App"
        windowRect = try? container.decodeIfPresent(CGRect.self, forKey: .windowRect)
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp, bundleID, appName, windowRect
    }

    /// Whether this is the app called `name` (its name or bundle ID, ignoring case).
    func isApp(_ name: String) -> Bool {
        AppFocusTimeline.matches(name, appName: appName, bundleID: bundleID)
    }
}

/// A stretch of a take with one app in front.
struct AppFocusSpan: Equatable {
    var span: TimeSpan
    var appName: String
    var bundleID: String?

    /// Whether this is the app called `name` (its name or bundle ID, ignoring case).
    func isApp(_ name: String) -> Bool {
        AppFocusTimeline.matches(name, appName: appName, bundleID: bundleID)
    }
}

/// Reading the record of which app was in front.
enum AppFocusTimeline {
    /// Window moves smaller than this (of the recording) don't make a new event.
    static let windowTolerance: CGFloat = 0.005

    /// Whether `name` is the app called `appName` or with `bundleID`, ignoring case and
    /// surrounding spaces.
    static func matches(_ name: String, appName: String, bundleID: String?) -> Bool {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return false }
        return appName.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            || bundleID?.compare(wanted, options: .caseInsensitive) == .orderedSame
    }

    /// Adds `event` unless nothing changed since the last one.
    static func append(_ event: AppFocusEvent, to events: inout [AppFocusEvent]) {
        if let last = events.last, last.appName == event.appName, last.bundleID == event.bundleID,
           sameWindow(last.windowRect, event.windowRect) {
            return
        }
        events.append(event)
    }

    static func sameWindow(_ first: CGRect?, _ second: CGRect?) -> Bool {
        switch (first, second) {
        case (nil, nil):
            return true
        case let (a?, b?):
            return abs(a.minX - b.minX) < windowTolerance && abs(a.minY - b.minY) < windowTolerance
                && abs(a.width - b.width) < windowTolerance && abs(a.height - b.height) < windowTolerance
        default:
            return false
        }
    }

    /// Who was in front when, until `duration`; neighbouring events of one app are joined.
    static func spans(_ events: [AppFocusEvent], duration: TimeInterval) -> [AppFocusSpan] {
        let sorted = events.sorted { $0.timestamp < $1.timestamp }
        var result: [AppFocusSpan] = []
        for (index, event) in sorted.enumerated() {
            let start = max(event.timestamp, 0)
            let end = index + 1 < sorted.count ? sorted[index + 1].timestamp : duration
            guard end > start else { continue }
            if let last = result.last, last.appName == event.appName, last.bundleID == event.bundleID {
                result[result.count - 1].span.end = end
            } else {
                result.append(AppFocusSpan(span: TimeSpan(start: start, end: end), appName: event.appName, bundleID: event.bundleID))
            }
        }
        return result
    }

    /// Seconds each app was in front, most first.
    static func timeByApp(_ events: [AppFocusEvent], duration: TimeInterval) -> [(appName: String, seconds: TimeInterval)] {
        var totals: [String: TimeInterval] = [:]
        var order: [String] = []
        for span in spans(events, duration: duration) {
            if totals[span.appName] == nil {
                order.append(span.appName)
            }
            totals[span.appName, default: 0] += span.span.duration
        }
        return order.map { (appName: $0, seconds: totals[$0] ?? 0) }.sorted { $0.seconds > $1.seconds }
    }

    /// The apps that were in front, quoted, most time first: `"Acme", "Slack"`.
    static func quotedNames(_ events: [AppFocusEvent], duration: TimeInterval) -> String {
        timeByApp(events, duration: duration).map { "\"\($0.appName)\"" }.joined(separator: ", ")
    }

    /// The app in front for the most time.
    static func dominantApp(_ events: [AppFocusEvent], duration: TimeInterval) -> String? {
        timeByApp(events, duration: duration).first?.appName
    }

    /// The box around everywhere `app`'s front window was in the recording, for cropping
    /// to it; `nil` if it never showed.
    static func windowUnion(of app: String, in events: [AppFocusEvent]) -> CGRect? {
        SourceCrop.union(events.filter { $0.isApp(app) }.compactMap(\.windowRect))
    }
}
