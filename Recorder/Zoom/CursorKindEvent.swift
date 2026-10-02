import Foundation

/// The system cursor's shape, so the rendered cursor can change like the real one.
enum CursorKind: String, Codable, CaseIterable {
    case arrow
    case iBeam
    case pointingHand

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CursorKind(rawValue: raw) ?? .arrow
    }
}

/// The cursor changed shape at `timestamp` (recording seconds). Only changes are stored.
struct CursorKindEvent: Codable, Equatable {
    let timestamp: TimeInterval
    let kind: CursorKind
}

enum CursorKindTimeline {
    /// The cursor's shape at `time`: the last change at or before it, an arrow before any.
    /// `events` must be sorted by time.
    static func kind(at time: TimeInterval, in events: [CursorKindEvent]) -> CursorKind {
        var low = 0
        var high = events.count
        while low < high {
            let mid = (low + high) / 2
            if events[mid].timestamp <= time {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low == 0 ? .arrow : events[low - 1].kind
    }

    /// Appends `kind` at `time` unless it's the same as the current shape.
    static func append(_ kind: CursorKind, at time: TimeInterval, to events: inout [CursorKindEvent]) {
        let current = events.last?.kind ?? .arrow
        guard kind != current else { return }
        events.append(CursorKindEvent(timestamp: time, kind: kind))
    }
}

/// `inputs.json`: key presses and cursor shapes recorded with a take (newer than
/// events.json and cursor.json, so kept separately and optional).
struct InputLog: Codable, Equatable {
    var keystrokes: [KeystrokeEvent] = []
    var cursorKinds: [CursorKindEvent] = []
    /// Which app was in front, and where its window was (takes from before this have none).
    var appFocus: [AppFocusEvent] = []

    init(keystrokes: [KeystrokeEvent] = [], cursorKinds: [CursorKindEvent] = [], appFocus: [AppFocusEvent] = []) {
        self.keystrokes = keystrokes
        self.cursorKinds = cursorKinds
        self.appFocus = appFocus
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keystrokes = (try? container.decodeIfPresent([KeystrokeEvent].self, forKey: .keystrokes)) ?? []
        cursorKinds = (try? container.decodeIfPresent([CursorKindEvent].self, forKey: .cursorKinds)) ?? []
        appFocus = (try? container.decodeIfPresent([AppFocusEvent].self, forKey: .appFocus)) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case keystrokes
        case cursorKinds
        case appFocus
    }
}
