import Foundation

/// A stretch of a segment played at one speed. A segment without ramps is one piece.
struct SpeedPiece: Equatable {
    /// Source seconds.
    var source: TimeSpan
    /// Output seconds from the segment's start.
    var outputOffset: TimeInterval
    var outputDuration: TimeInterval
    var speed: Double

    var outputEnd: TimeInterval {
        outputOffset + outputDuration
    }
}

/// Easing into and out of sped-up parts instead of jumping speed.
///
/// Only a segment faster than 1× ramps, and only on a side where it meets a slower
/// segment without a cut; it eases from that neighbour's speed. Each ramp lasts up to the
/// ramp time (output seconds, at most a quarter of the segment) in a few constant-speed
/// steps, so compositions can still be built from scaled time ranges. To keep the
/// segment's length, its middle plays a little faster: the segment covers the same
/// source in the same output time, so everything laid out on the timeline stays put.
enum SpeedRamp {
    /// Each ramp is this many constant-speed steps…
    static let steps = 4
    /// …this far from the neighbour's speed to the peak: smoothstep at the steps'
    /// midpoints. They average ½, so a ramp covers as much source as a straight line.
    static let fractions: [Double] = [0.04296875, 0.31640625, 0.68359375, 0.95703125]
    /// A peak faster than this drops the ramps (the segment plays as it would without).
    static let maximumSpeed: Double = 24
    /// What "smooth speed changes" turns on.
    static let defaultRamp: TimeInterval = 0.35

    /// The pieces of `segments[index]` with ramps of up to `ramp` seconds.
    static func pieces(of segments: [EditSegment], at index: Int, ramp: TimeInterval) -> [SpeedPiece] {
        let segment = segments[index]
        let whole = [SpeedPiece(source: segment.source, outputOffset: 0, outputDuration: segment.outputDuration, speed: segment.speed)]
        let speed = segment.speed
        let sourceLength = segment.source.duration
        let outputLength = segment.outputDuration
        guard ramp > 0, speed > 1 + 1e-9, sourceLength > 0, outputLength > 0 else { return whole }

        // A slower neighbour joined without a cut eases into or out of this segment.
        var incoming: Double?
        if index > 0 {
            let previous = segments[index - 1]
            if abs(previous.source.end - segment.source.start) < 1e-6, previous.speed < speed - 1e-9 {
                incoming = previous.speed
            }
        }
        var outgoing: Double?
        if index + 1 < segments.count {
            let next = segments[index + 1]
            if abs(next.source.start - segment.source.end) < 1e-6, next.speed < speed - 1e-9 {
                outgoing = next.speed
            }
        }
        guard incoming != nil || outgoing != nil else { return whole }

        let rampIn = incoming == nil ? 0 : min(ramp, outputLength / 4)
        let rampOut = outgoing == nil ? 0 : min(ramp, outputLength / 4)
        let peak = (sourceLength - 0.5 * (rampIn * (incoming ?? 0) + rampOut * (outgoing ?? 0)))
            / (outputLength - 0.5 * (rampIn + rampOut))
        guard peak.isFinite, peak > 0, peak <= maximumSpeed else { return whole }

        var pieces: [SpeedPiece] = []
        var output: TimeInterval = 0
        var source = segment.source.start
        func add(_ duration: TimeInterval, at pieceSpeed: Double) {
            guard duration > 0 else { return }
            let length = duration * pieceSpeed
            pieces.append(SpeedPiece(
                source: TimeSpan(start: source, end: source + length),
                outputOffset: output,
                outputDuration: duration,
                speed: pieceSpeed
            ))
            output += duration
            source += length
        }
        if let incoming {
            for fraction in fractions {
                add(rampIn / Double(steps), at: incoming + fraction * (peak - incoming))
            }
        }
        add(outputLength - rampIn - rampOut, at: peak)
        if let outgoing {
            for fraction in fractions {
                add(rampOut / Double(steps), at: peak + fraction * (outgoing - peak))
            }
        }
        // Rounding: end exactly where the segment does.
        if !pieces.isEmpty {
            pieces[pieces.count - 1].source.end = segment.source.end
        }
        return pieces
    }

    /// The source time `offset` output seconds into a segment made of `pieces`.
    static func sourceTime(forOffset offset: TimeInterval, in pieces: [SpeedPiece]) -> TimeInterval {
        for piece in pieces where offset < piece.outputEnd {
            return piece.source.start + max(offset - piece.outputOffset, 0) * piece.speed
        }
        return pieces.last?.source.end ?? 0
    }

    /// How far into a segment made of `pieces` source time `time` plays (output seconds).
    static func outputOffset(forSource time: TimeInterval, in pieces: [SpeedPiece]) -> TimeInterval {
        for piece in pieces where time < piece.source.end {
            return piece.outputOffset + max(time - piece.source.start, 0) / piece.speed
        }
        return pieces.last?.outputEnd ?? 0
    }
}
