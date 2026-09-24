import CoreGraphics
import Foundation

struct CursorEvent: Codable, Equatable {
    let timestamp: TimeInterval
    let locationX: CGFloat
    let locationY: CGFloat

    var location: CGPoint {
        CGPoint(x: locationX, y: locationY)
    }

    init(timestamp: TimeInterval, location: CGPoint) {
        self.timestamp = timestamp
        self.locationX = location.x
        self.locationY = location.y
    }
}

struct CursorPathSmoother {
    private let smoothingFactor: CGFloat = 0.35

    func smooth(_ events: [CursorEvent]) -> [CursorEvent] {
        guard !events.isEmpty else { return [] }

        var smoothed: [CursorEvent] = []
        smoothed.reserveCapacity(events.count)

        var current = events[0].location
        smoothed.append(events[0])

        for event in events.dropFirst() {
            current = CGPoint(
                x: current.x + (event.location.x - current.x) * smoothingFactor,
                y: current.y + (event.location.y - current.y) * smoothingFactor
            )
            smoothed.append(CursorEvent(timestamp: event.timestamp, location: current))
        }

        return smoothed
    }

    /// Cursor position at `time`, interpolated between samples. `events` must be sorted
    /// by timestamp (they are recorded in order). Runs every rendered frame, so it uses a
    /// binary search rather than scanning the whole path.
    func location(at time: TimeInterval, in events: [CursorEvent]) -> CGPoint? {
        guard let first = events.first, let last = events.last else { return nil }

        if time <= first.timestamp {
            return first.location
        }
        if time >= last.timestamp {
            return last.location
        }

        // Find the first sample after `time`; the one before it is at or before `time`.
        var low = 1
        var high = events.count - 1
        while low < high {
            let mid = (low + high) / 2
            if events[mid].timestamp > time {
                high = mid
            } else {
                low = mid + 1
            }
        }

        let current = events[low - 1]
        let next = events[low]
        let span = next.timestamp - current.timestamp
        guard span > 0 else { return current.location }
        let progress = CGFloat((time - current.timestamp) / span)
        return CGPoint(
            x: current.location.x + (next.location.x - current.location.x) * progress,
            y: current.location.y + (next.location.y - current.location.y) * progress
        )
    }
}
