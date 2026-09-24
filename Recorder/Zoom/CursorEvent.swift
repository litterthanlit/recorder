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
    /// How quickly the smoothed cursor follows the real one: it closes ~63% of the gap
    /// in this time, whatever the sample rate.
    var timeConstant: TimeInterval = 0.07
    /// Step of the smoothed path while it's moving.
    var sampleInterval: TimeInterval = 1.0 / 120.0
    /// Around a click the smoothed cursor blends onto the real path, reaching the click
    /// point exactly at the click, so ripples and zooms line up with the arrow tip.
    var clickAnchorWindow: TimeInterval = 0.15
    /// Closer than this (source pixels) to where the real cursor is resting counts as
    /// settled, so idle stretches don't produce samples.
    var settleDistance: CGFloat = 0.25

    /// A smoothed copy of `events`, sampled on a fixed time step.
    ///
    /// Cursor samples only arrive while the mouse moves, so smoothing sample by sample
    /// left the arrow frozen short of where it stopped. This follows the real path in
    /// time instead, keeps going after the last movement until it has caught up, and
    /// passes through every click.
    func smooth(_ events: [CursorEvent], clicks: [ClickEvent] = []) -> [CursorEvent] {
        let clickEvents = clicks
            .map { CursorEvent(timestamp: $0.timestamp, location: $0.location) }
            .sorted { $0.timestamp < $1.timestamp }
        // Clicks are exact positions too: the path goes through them.
        let raw = (events + clickEvents).sorted { $0.timestamp < $1.timestamp }
        guard let first = raw.first, let last = raw.last else { return [] }

        let step = max(sampleInterval, 0.001)
        let tau = max(timeConstant, 0.001)
        let clickTimes = clickEvents.map(\.timestamp)

        var smoothed = [first]
        var state = first.location
        var time = first.timestamp
        var nextRawIndex = 1
        var nextClickIndex = 0

        while true {
            while nextRawIndex < raw.count, raw[nextRawIndex].timestamp <= time {
                nextRawIndex += 1
            }
            while nextClickIndex < clickTimes.count, clickTimes[nextClickIndex] <= time {
                nextClickIndex += 1
            }

            let target = location(at: time, in: raw) ?? state
            let settled = hypot(state.x - target.x, state.y - target.y) < settleDistance
            if settled && time >= last.timestamp {
                break
            }

            // Caught up: skip ahead to just before the next sample. The path between
            // samples is linear, so the skipped stretch is reproduced by interpolation.
            var nextTime = time + step
            if settled, nextRawIndex < raw.count {
                nextTime = max(nextTime, raw[nextRawIndex].timestamp - step)
            }
            // Land exactly on clicks.
            if nextClickIndex < clickTimes.count {
                nextTime = min(nextTime, clickTimes[nextClickIndex])
            }

            let deltaTime = nextTime - time
            time = nextTime
            let goal = location(at: time, in: raw) ?? state
            let alpha = CGFloat(1 - exp(-deltaTime / tau))
            state = CGPoint(x: state.x + (goal.x - state.x) * alpha, y: state.y + (goal.y - state.y) * alpha)

            let anchor = clickAnchorWeight(at: time, clickTimes: clickTimes, nextIndex: nextClickIndex)
            if anchor > 0 {
                state = CGPoint(x: state.x + (goal.x - state.x) * anchor, y: state.y + (goal.y - state.y) * anchor)
            }
            smoothed.append(CursorEvent(timestamp: time, location: state))
        }

        return smoothed
    }

    /// 1 at a click, falling to 0 `clickAnchorWindow` away from it. Clicks before
    /// `nextIndex` are at or before `time`'s previous step; the one at `nextIndex` is at or
    /// after `time`, so those two are the nearest.
    private func clickAnchorWeight(at time: TimeInterval, clickTimes: [TimeInterval], nextIndex: Int) -> CGFloat {
        guard clickAnchorWindow > 0 else { return 0 }
        var nearest = TimeInterval.infinity
        for index in [nextIndex - 1, nextIndex] where clickTimes.indices.contains(index) {
            nearest = min(nearest, abs(clickTimes[index] - time))
        }
        return CGFloat(max(0, 1 - nearest / clickAnchorWindow))
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
