import CoreMedia
import Foundation
import QuartzCore

/// One take's clock, shared by the screen writer, the camera track, input tracking and
/// the on-screen timer. Wraps `PauseLedger` (t = 0 is the first screen frame; paused time
/// is taken out) behind a lock, since those run on different queues.
final class RecordingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var ledger = PauseLedger()

    /// Called with the first screen frame's host time. Only the first call counts.
    func setEpoch(_ host: CMTime) {
        locked { ledger.setEpoch(host) }
    }

    var hasEpoch: Bool {
        locked { ledger.epoch != nil }
    }

    var isPaused: Bool {
        locked { ledger.isPaused }
    }

    func pause(at host: CMTime = RecordingClock.now) {
        locked { ledger.pause(at: host) }
    }

    func resume(at host: CMTime = RecordingClock.now) {
        locked { ledger.resume(at: host) }
    }

    /// Where a sample captured at `host` goes in the recording; `nil` if it isn't recorded.
    func recordingTime(forHost host: CMTime) -> CMTime? {
        locked { ledger.recordingTime(forHost: host) }
    }

    /// `recordingTime(forHost:)` in seconds, for `CACurrentMediaTime()` values.
    func recordingSeconds(forHostSeconds seconds: TimeInterval) -> TimeInterval? {
        recordingTime(forHost: Self.time(seconds)).map(CMTimeGetSeconds)
    }

    func keptRange(bufferStart: CMTime, duration: CMTime) -> CMTimeRange? {
        locked { ledger.keptRange(bufferStart: bufferStart, duration: duration) }
    }

    /// Recorded time so far; stops advancing while paused.
    func activeDuration(atHost host: CMTime = RecordingClock.now) -> CMTime {
        locked { ledger.activeDuration(atHost: host) }
    }

    var pausePoints: [TimeInterval] {
        locked { ledger.pausePoints }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    static var now: CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }

    private static func time(_ seconds: TimeInterval) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
    }
}
