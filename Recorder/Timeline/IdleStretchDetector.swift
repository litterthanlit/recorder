import Foundation

/// Finds dead air: stretches where nothing happens (no clicks, pointer movement or key
/// presses), so they can be sped up in one go.
enum IdleStretchDetector {
    /// Idle stretches of at least `minimumIdle` seconds inside `range`, each pulled in by
    /// `padding` on both sides so the moments around the activity keep normal speed.
    /// - Parameter activity: when something happened, in source seconds (any order).
    static func idleStretches(
        activity: [TimeInterval],
        within range: TimeSpan,
        minimumIdle: TimeInterval = 2,
        padding: TimeInterval = 0.4
    ) -> [TimeSpan] {
        guard range.duration > 0 else { return [] }
        let times = activity.filter { range.contains($0) }.sorted()
        // The range's own edges need no padding: nothing happens beyond them.
        let boundaries: [(time: TimeInterval, isEdge: Bool)] = [(time: range.start, isEdge: true)]
            + times.map { (time: $0, isEdge: false) }
            + [(time: range.end, isEdge: true)]
        var stretches: [TimeSpan] = []
        for (previous, next) in zip(boundaries, boundaries.dropFirst()) {
            let start = previous.isEdge ? previous.time : previous.time + padding
            let end = next.isEdge ? next.time : next.time - padding
            if end - start >= minimumIdle {
                stretches.append(TimeSpan(start: start, end: end))
            }
        }
        return stretches
    }

    /// Everything that counts as activity in a take.
    static func activityTimes(
        clicks: [ClickEvent],
        cursor: [CursorEvent],
        keystrokes: [KeystrokeEvent]
    ) -> [TimeInterval] {
        clicks.map(\.timestamp) + cursor.map(\.timestamp) + keystrokes.map(\.timestamp)
    }
}
