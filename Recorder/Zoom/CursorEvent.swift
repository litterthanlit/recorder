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

    func location(at time: TimeInterval, in events: [CursorEvent]) -> CGPoint? {
        guard !events.isEmpty else { return nil }

        if time <= events[0].timestamp {
            return events[0].location
        }

        if let last = events.last, time >= last.timestamp {
            return last.location
        }

        for index in 0..<(events.count - 1) {
            let current = events[index]
            let next = events[index + 1]
            if time >= current.timestamp && time <= next.timestamp {
                let span = next.timestamp - current.timestamp
                guard span > 0 else { return current.location }
                let progress = CGFloat((time - current.timestamp) / span)
                return CGPoint(
                    x: current.location.x + (next.location.x - current.location.x) * progress,
                    y: current.location.y + (next.location.y - current.location.y) * progress
                )
            }
        }

        return events.last?.location
    }
}
