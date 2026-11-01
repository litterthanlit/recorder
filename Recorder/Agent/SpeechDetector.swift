import Foundation

/// Finds speech in a microphone track from its loudness: `margin` dB louder than the
/// room's own noise, held through the short pauses between words. The noise floor falls
/// at once to anything quieter and rises slowly, so it follows a fan switching on without
/// mistaking a long sentence for noise.
struct SpeechDetector {
    /// Loudness frames per second.
    var frameRate: Double = 50
    /// How far above the noise floor counts as speech, dB.
    var margin: Double = 12
    /// Quieter than this (dBFS) is never speech, however quiet the room.
    var absoluteThreshold: Double = -50
    /// How fast the noise floor may rise, dB per second.
    var floorRise: Double = 1
    /// Speech goes on through pauses shorter than this.
    var hangover: TimeInterval = 0.35
    /// Shorter bursts (a click, a cough) aren't speech.
    var minimumSpeech: TimeInterval = 0.2

    /// The level of digital silence.
    static let silence: Double = -120

    /// dBFS of a root-mean-square amplitude (1 is full scale).
    static func decibels(rms: Double) -> Double {
        rms > 1e-6 ? max(20 * log10(rms), silence) : silence
    }

    /// Speech in seconds, from levels (dBFS) at `frameRate` per second, the first of them
    /// at `start`.
    func speech(levels: [Double], start: TimeInterval = 0) -> [TimeSpan] {
        guard !levels.isEmpty, frameRate > 0 else { return [] }
        let frame = 1 / frameRate
        let hangoverFrames = max(1, Int((hangover * frameRate).rounded()))
        var floor = Self.percentile(levels, 0.1)

        var spans: [TimeSpan] = []
        var runStart: Int?
        var lastLoud = 0
        func close() {
            guard let first = runStart else { return }
            let span = TimeSpan(start: start + Double(first) * frame, end: start + Double(lastLoud + 1) * frame)
            if span.duration >= minimumSpeech {
                spans.append(span)
            }
            runStart = nil
        }

        for (index, level) in levels.enumerated() {
            floor = level < floor ? level : min(floor + floorRise * frame, level)
            let loud = level >= max(floor + margin, absoluteThreshold)
            if loud {
                if runStart == nil {
                    runStart = index
                }
                lastLoud = index
            } else if runStart != nil, index - lastLoud > hangoverFrames {
                close()
            }
        }
        close()
        return spans
    }

    /// The value below which `fraction` of `values` fall.
    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return silence }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * fraction)))
        return sorted[index]
    }
}

/// Loudness (dBFS) of consecutive runs of `frameLength` audio samples, for
/// `SpeechDetector`.
struct LoudnessMeter {
    let frameLength: Int
    private(set) var levels: [Double] = []
    /// Samples taken in so far, silence padding included.
    private(set) var position = 0
    private var sum: Double = 0
    private var filled = 0

    init(frameLength: Int) {
        self.frameLength = max(1, frameLength)
    }

    mutating func add(_ samples: [Float]) {
        for sample in samples {
            sum += Double(sample) * Double(sample)
            filled += 1
            position += 1
            if filled == frameLength {
                flush()
            }
        }
    }

    /// Silence up to sample `index`, when that's more than a frame ahead (audio that
    /// went missing), so later levels stay in place.
    mutating func pad(toSample index: Int) {
        let missing = index - position
        guard missing > frameLength else { return }
        add([Float](repeating: 0, count: missing))
    }

    /// All the levels, the last (partial) frame included.
    mutating func finish() -> [Double] {
        if filled > 0 {
            flush()
        }
        return levels
    }

    private mutating func flush() {
        levels.append(SpeechDetector.decibels(rms: (sum / Double(max(filled, 1))).squareRoot()))
        sum = 0
        filled = 0
    }
}
