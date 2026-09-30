import CoreMedia
import Foundation

/// The recording's clock with paused stretches taken out.
///
/// t = 0 is the first screen frame (`epoch`, on the host clock). While paused, nothing is
/// written; after resuming, timestamps continue from where the pause began, so the movie,
/// the camera track, clicks and cursor stay on one continuous timeline. Shifting
/// timestamps (rather than leaving gaps to cut later) also keeps AAC audio in place: the
/// writer's audio input doesn't reliably preserve gaps between buffers.
///
/// With no pauses, `recordingTime(forHost:)` is exactly `host − epoch`, as before pausing
/// existed.
struct PauseLedger: Equatable {
    private struct Pause: Equatable {
        var start: CMTime
        var end: CMTime?
    }

    private(set) var epoch: CMTime?
    private var pauses: [Pause] = []

    var isPaused: Bool {
        pauses.last.map { $0.end == nil } ?? false
    }

    /// Sets t = 0. Only the first call counts.
    mutating func setEpoch(_ host: CMTime) {
        if epoch == nil, host.isValid {
            epoch = host
        }
    }

    mutating func pause(at host: CMTime) {
        guard !isPaused, host.isValid else { return }
        pauses.append(Pause(start: host, end: nil))
    }

    mutating func resume(at host: CMTime) {
        guard isPaused, host.isValid, let index = pauses.indices.last else { return }
        pauses[index].end = CMTimeMaximum(host, pauses[index].start)
    }

    /// Whether `host` falls inside a pause (a pause includes its start, not its end).
    func isInPause(_ host: CMTime) -> Bool {
        pauses.contains { pause in
            host >= pause.start && (pause.end.map { host < $0 } ?? true)
        }
    }

    /// Paused time between the epoch and `host`.
    func pausedDuration(upTo host: CMTime) -> CMTime {
        guard let epoch else { return .zero }
        var total = CMTime.zero
        for pause in pauses {
            let start = CMTimeMaximum(pause.start, epoch)
            let end = CMTimeMinimum(pause.end ?? host, host)
            if end > start {
                total = CMTimeAdd(total, CMTimeSubtract(end, start))
            }
        }
        return total
    }

    /// Where `host` lands on the recording's timeline; `nil` before t = 0 or while paused
    /// (such samples aren't recorded).
    func recordingTime(forHost host: CMTime) -> CMTime? {
        guard let epoch, host.isValid, host >= epoch, !isInPause(host) else { return nil }
        return CMTimeSubtract(CMTimeSubtract(host, epoch), pausedDuration(upTo: host))
    }

    /// How much has been recorded by `host` (the on-screen timer); holds still while paused.
    func activeDuration(atHost host: CMTime) -> CMTime {
        guard let epoch, host.isValid, host > epoch else { return .zero }
        return CMTimeSubtract(CMTimeSubtract(host, epoch), pausedDuration(upTo: host))
    }

    /// Where each pause happened on the recording's timeline, in seconds.
    var pausePoints: [TimeInterval] {
        guard let epoch else { return [] }
        return pauses
            .filter { $0.start >= epoch }
            .map { CMTimeGetSeconds(activeDuration(atHost: $0.start)) }
    }

    /// The part of a buffer covering `[start, start + duration)` (host time) that falls
    /// outside pauses and after t = 0, or `nil` if none does. A buffer that straddles the
    /// start of a pause keeps its beginning; one that straddles the end keeps its end.
    func keptRange(bufferStart start: CMTime, duration: CMTime) -> CMTimeRange? {
        guard let epoch, start.isValid, duration.isValid, duration > .zero else { return nil }
        var keepStart = CMTimeMaximum(start, epoch)
        var keepEnd = CMTimeAdd(start, duration)
        guard keepEnd > keepStart else { return nil }

        for pause in pauses {
            let pauseEnd = pause.end ?? .positiveInfinity
            if pauseEnd <= keepStart || pause.start >= keepEnd { continue }
            if pause.start <= keepStart {
                keepStart = pauseEnd
            } else {
                keepEnd = pause.start
            }
            if !keepStart.isNumeric || keepEnd <= keepStart { return nil }
        }
        return CMTimeRange(start: keepStart, end: keepEnd)
    }
}
