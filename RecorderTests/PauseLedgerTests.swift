import CoreMedia
import Foundation
import Testing
@testable import RecorderCore

@Suite("PauseLedger")
struct PauseLedgerTests {
    private func t(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 1_000_000)
    }

    private func seconds(_ time: CMTime?) -> Double? {
        time.map(CMTimeGetSeconds)
    }

    @Test func withoutPausesItIsHostMinusEpoch() {
        var ledger = PauseLedger()
        ledger.setEpoch(t(100))
        for host in [100.0, 100.5, 137.25, 1000] {
            let expected = MediaTiming.recordingTime(hostTime: t(host), firstVideoFrameHostTime: t(100))
            #expect(ledger.recordingTime(forHost: t(host)) == expected)
        }
        #expect(ledger.recordingTime(forHost: t(99.9)) == nil)
        #expect(ledger.pausePoints.isEmpty)
    }

    @Test func onlyTheFirstEpochCounts() {
        var ledger = PauseLedger()
        ledger.setEpoch(t(10))
        ledger.setEpoch(t(20))
        #expect(ledger.epoch == t(10))
    }

    @Test func removesPausedTime() throws {
        var ledger = PauseLedger()
        ledger.setEpoch(t(100))
        ledger.pause(at: t(110))
        #expect(ledger.isPaused)
        ledger.resume(at: t(115))
        #expect(!ledger.isPaused)

        #expect(isClose(try #require(seconds(ledger.recordingTime(forHost: t(109)))), 9))
        #expect(ledger.recordingTime(forHost: t(110)) == nil)
        #expect(ledger.recordingTime(forHost: t(114.9)) == nil)
        #expect(isClose(try #require(seconds(ledger.recordingTime(forHost: t(115)))), 10))
        #expect(isClose(try #require(seconds(ledger.recordingTime(forHost: t(120)))), 15))
        #expect(ledger.pausePoints.count == 1)
        #expect(isClose(ledger.pausePoints[0], 10))
    }

    @Test func handlesSeveralPauses() throws {
        var ledger = PauseLedger()
        ledger.setEpoch(t(0))
        ledger.pause(at: t(2))
        ledger.resume(at: t(3))
        ledger.pause(at: t(5))
        ledger.resume(at: t(9))
        #expect(isClose(try #require(seconds(ledger.recordingTime(forHost: t(10)))), 5))
        #expect(isClose(CMTimeGetSeconds(ledger.pausedDuration(upTo: t(10))), 5))
        // Recorded 0–2 s, then 3–5 s: the second pause comes 4 s into the recording.
        #expect(ledger.pausePoints.map { ($0 * 1000).rounded() / 1000 } == [2, 4])
    }

    @Test func timerHoldsStillWhilePaused() {
        var ledger = PauseLedger()
        ledger.setEpoch(t(50))
        ledger.pause(at: t(60))
        #expect(isClose(CMTimeGetSeconds(ledger.activeDuration(atHost: t(60))), 10))
        #expect(isClose(CMTimeGetSeconds(ledger.activeDuration(atHost: t(75))), 10))
        #expect(ledger.recordingTime(forHost: t(75)) == nil)
        ledger.resume(at: t(80))
        #expect(isClose(CMTimeGetSeconds(ledger.activeDuration(atHost: t(81))), 11))
        #expect(isClose(CMTimeGetSeconds(ledger.activeDuration(atHost: t(40))), 0))
    }

    @Test func pauseAndResumeAreIdempotent() throws {
        var ledger = PauseLedger()
        ledger.setEpoch(t(0))
        ledger.resume(at: t(1))
        ledger.pause(at: t(2))
        ledger.pause(at: t(3))
        ledger.resume(at: t(4))
        ledger.resume(at: t(6))
        #expect(isClose(try #require(seconds(ledger.recordingTime(forHost: t(7)))), 5))
    }

    @Test func keepsTheUnpausedPartOfAudioBuffers() throws {
        var ledger = PauseLedger()
        ledger.setEpoch(t(10))
        ledger.pause(at: t(20))
        ledger.resume(at: t(30))

        // Whole buffer before the pause.
        let before = try #require(ledger.keptRange(bufferStart: t(15), duration: t(0.02)))
        #expect(before.start == t(15) && isClose(CMTimeGetSeconds(before.duration), 0.02))
        // Straddles the pause start: keep the beginning.
        let intoPause = try #require(ledger.keptRange(bufferStart: t(19.99), duration: t(0.02)))
        #expect(isClose(CMTimeGetSeconds(intoPause.start), 19.99))
        #expect(isClose(CMTimeGetSeconds(intoPause.end), 20))
        // Entirely inside the pause.
        #expect(ledger.keptRange(bufferStart: t(25), duration: t(0.02)) == nil)
        // Straddles the resume: keep the end.
        let outOfPause = try #require(ledger.keptRange(bufferStart: t(29.99), duration: t(0.02)))
        #expect(isClose(CMTimeGetSeconds(outOfPause.start), 30))
        #expect(isClose(CMTimeGetSeconds(outOfPause.end), 30.01, tolerance: 1e-9))
        // Straddles t = 0.
        let atStart = try #require(ledger.keptRange(bufferStart: t(9.99), duration: t(0.02)))
        #expect(atStart.start == t(10))
        // During an open pause nothing is kept.
        ledger.pause(at: t(40))
        #expect(ledger.keptRange(bufferStart: t(41), duration: t(0.02)) == nil)
        let beforeOpen = try #require(ledger.keptRange(bufferStart: t(39.99), duration: t(0.02)))
        #expect(isClose(CMTimeGetSeconds(beforeOpen.end), 40))
    }
}
