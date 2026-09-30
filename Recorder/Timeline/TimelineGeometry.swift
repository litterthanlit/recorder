import CoreGraphics
import Foundation

/// Maps output time to horizontal position on the timeline.
struct TimelineScale: Equatable {
    /// Points per second of output time.
    var pointsPerSecond: CGFloat
    /// Output duration (the edited length).
    var duration: TimeInterval

    static let pointsPerSecondRange: ClosedRange<CGFloat> = 1...800

    init(pointsPerSecond: CGFloat, duration: TimeInterval) {
        self.pointsPerSecond = min(max(pointsPerSecond, Self.pointsPerSecondRange.lowerBound), Self.pointsPerSecondRange.upperBound)
        self.duration = max(0, duration)
    }

    /// The scale that shows all of `duration` in `width` points.
    static func fitting(duration: TimeInterval, width: CGFloat) -> TimelineScale {
        let safeDuration = max(duration, 0.1)
        return TimelineScale(pointsPerSecond: max(width, 1) / CGFloat(safeDuration), duration: duration)
    }

    var contentWidth: CGFloat {
        CGFloat(duration) * pointsPerSecond
    }

    func x(for time: TimeInterval) -> CGFloat {
        CGFloat(time) * pointsPerSecond
    }

    /// The time at `x`, within the timeline.
    func time(for x: CGFloat) -> TimeInterval {
        min(max(TimeInterval(x / pointsPerSecond), 0), duration)
    }

    /// Zoomed by `factor`, but never narrower than `minimumWidth` (fitting the window).
    func zoomed(by factor: CGFloat, minimumWidth: CGFloat) -> TimelineScale {
        let fit = Self.fitting(duration: duration, width: minimumWidth).pointsPerSecond
        let next = max(pointsPerSecond * factor, fit)
        return TimelineScale(pointsPerSecond: next, duration: duration)
    }
}

struct TimelineTick: Equatable {
    var time: TimeInterval
    /// Major ticks are taller and labelled.
    var isMajor: Bool
}

enum TimelineRuler {
    /// Major and minor tick intervals, from fine to coarse.
    static let intervals: [(major: TimeInterval, minor: TimeInterval)] = [
        (0.1, 0.02), (0.25, 0.05), (0.5, 0.1), (1, 0.25), (2, 0.5), (5, 1), (10, 2),
        (15, 5), (30, 5), (60, 15), (120, 30), (300, 60), (600, 120)
    ]

    /// The finest intervals whose labels are at least `minimumSpacing` points apart.
    static func intervals(pointsPerSecond: CGFloat, minimumSpacing: CGFloat = 72) -> (major: TimeInterval, minor: TimeInterval) {
        intervals.first { CGFloat($0.major) * pointsPerSecond >= minimumSpacing } ?? intervals[intervals.count - 1]
    }

    /// Ticks from `start` to `end` (the visible part), at most a few hundred.
    static func ticks(
        from start: TimeInterval,
        to end: TimeInterval,
        pointsPerSecond: CGFloat,
        minimumSpacing: CGFloat = 72
    ) -> [TimelineTick] {
        guard end > start, pointsPerSecond > 0 else { return [] }
        let chosen = intervals(pointsPerSecond: pointsPerSecond, minimumSpacing: minimumSpacing)
        let perMajor = max(1, Int((chosen.major / chosen.minor).rounded()))
        let first = Int((max(0, start) / chosen.minor).rounded(.down))
        let last = min(Int((end / chosen.minor).rounded(.up)), first + 2_000)
        guard last >= first else { return [] }
        return (first...last).map { index in
            TimelineTick(time: Double(index) * chosen.minor, isMajor: index % perMajor == 0)
        }
    }

    /// "0:05", "1:30", or with tenths ("0:01.5") when the ticks are less than a second
    /// apart.
    static func label(for time: TimeInterval, majorInterval: TimeInterval) -> String {
        let clamped = max(0, time)
        if majorInterval < 1 {
            let tenths = Int((clamped * 10).rounded())
            return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
        }
        let seconds = Int(clamped.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

enum TimelineSnapper {
    /// `time` moved to the nearest of `candidates` within `tolerance` (seconds), or
    /// unchanged when none is that close.
    static func snap(_ time: TimeInterval, to candidates: [TimeInterval], tolerance: TimeInterval) -> TimeInterval {
        var best: TimeInterval?
        var bestDistance = tolerance
        for candidate in candidates {
            let distance = abs(candidate - time)
            if distance <= bestDistance {
                best = candidate
                bestDistance = distance
            }
        }
        return best ?? time
    }
}

/// Timecodes shown in the editor.
enum Timecode {
    /// "1:05.3": minutes, seconds, tenths.
    static func precise(_ time: TimeInterval) -> String {
        let tenths = Int((max(0, time) * 10).rounded(.down))
        return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }

    /// "1:05".
    static func short(_ time: TimeInterval) -> String {
        let seconds = Int(max(0, time).rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// "1 minute 5.3 seconds", for VoiceOver.
    static func spoken(_ time: TimeInterval) -> String {
        let clamped = max(0, time)
        let minutes = Int(clamped / 60)
        let seconds = clamped - Double(minutes * 60)
        let secondsText = String(format: "%.1f seconds", seconds)
        guard minutes > 0 else { return secondsText }
        return "\(minutes) minute\(minutes == 1 ? "" : "s") \(secondsText)"
    }
}
