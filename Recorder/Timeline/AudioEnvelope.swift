import Foundation

/// A change in loudness over output time, as a multiplier of a track's level.
struct VolumeRamp: Equatable {
    var start: TimeInterval
    var duration: TimeInterval
    var from: Double
    var to: Double
}

/// Loudness changes along the edit: short fades at cuts so they don't click, and quiet
/// over sped-up parts so they don't chatter.
enum AudioEnvelope {
    /// Each side of a cut fades over this long.
    static let cutFade: TimeInterval = 0.04
    /// Muted parts fade out and back in over this long.
    static let muteRamp: TimeInterval = 0.08
    /// Pieces faster than this are muted (with `AudioMixSettings.muteSpedUp`).
    static let mutedAbove: Double = 2.5

    /// The ramps, in order and not overlapping; empty when nothing changes.
    static func ramps(for timeline: EditTimeline, audio: AudioMixSettings) -> [VolumeRamp] {
        let cuts = audio.cutFades ? CutTransitions.cutTimes(in: timeline) : []
        let muted = audio.muteSpedUp ? mutedSpans(in: timeline) : []
        guard !cuts.isEmpty || !muted.isEmpty else { return [] }

        // Breakpoints of the gain curve, evaluated as the quieter of the two curves.
        var times: [TimeInterval] = [0, timeline.outputDuration]
        for cut in cuts {
            times += [cut - cutFade, cut, cut + cutFade]
        }
        for span in muted {
            times += [span.start, span.start + muteRamp, span.end - muteRamp, span.end]
        }
        let end = timeline.outputDuration
        let sorted = Array(Set(times.map { min(max($0, 0), end) })).sorted()

        func gain(_ time: TimeInterval) -> Double {
            var value = 1.0
            for cut in cuts where abs(time - cut) < cutFade {
                value = min(value, abs(time - cut) / cutFade)
            }
            for span in muted where time >= span.start && time <= span.end {
                let edge = min(time - span.start, span.end - time)
                value = min(value, max(0, 1 - edge / muteRamp))
            }
            return value
        }

        // Between ramps the level holds where the last one ended.
        var ramps: [VolumeRamp] = []
        for (start, next) in zip(sorted, sorted.dropFirst()) where next - start > 1e-6 {
            let from = gain(start)
            let to = gain(next)
            if abs(from - to) > 1e-6 {
                ramps.append(VolumeRamp(start: start, duration: next - start, from: from, to: to))
            }
        }
        return ramps
    }

    /// The gain at output time 0 (before any ramp).
    static func initialGain(_ ramps: [VolumeRamp]) -> Double {
        guard let first = ramps.first, first.start <= 1e-9 else { return 1 }
        return first.from
    }

    /// Output spans played faster than `mutedAbove`, joined where they touch, at least
    /// long enough to fade out and back in.
    static func mutedSpans(in timeline: EditTimeline) -> [TimeSpan] {
        var spans: [TimeSpan] = []
        for entry in timeline.compositionPlan where entry.speed > mutedAbove {
            let span = TimeSpan(start: entry.outputStart, end: entry.outputStart + entry.outputDuration)
            if let last = spans.last, span.start - last.end < 1e-6 {
                spans[spans.count - 1].end = max(last.end, span.end)
            } else {
                spans.append(span)
            }
        }
        return spans.filter { $0.duration >= muteRamp * 2 }
    }
}
