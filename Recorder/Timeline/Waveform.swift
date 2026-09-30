import CoreGraphics
import Foundation

/// Audio levels for the timeline's waveform.
enum Waveform {
    /// Peaks per second of source audio that the app keeps.
    static let peaksPerSecond: Double = 100

    /// The loudest absolute sample in each run of `bucketSize` samples.
    static func peaks(from samples: [Float], bucketSize: Int) -> [Float] {
        guard bucketSize > 0, !samples.isEmpty else { return [] }
        var result: [Float] = []
        result.reserveCapacity(samples.count / bucketSize + 1)
        var index = 0
        while index < samples.count {
            let end = min(index + bucketSize, samples.count)
            var peak: Float = 0
            for sample in samples[index..<end] {
                peak = max(peak, abs(sample))
            }
            result.append(min(peak, 1))
            index = end
        }
        return result
    }

    /// The loudest peak between two source times, from peaks at `rate` per second.
    static func peak(in peaks: [Float], rate: Double = peaksPerSecond, from start: TimeInterval, to end: TimeInterval) -> Float {
        guard !peaks.isEmpty, rate > 0 else { return 0 }
        let first = max(0, Int((min(start, end) * rate).rounded(.down)))
        let last = min(peaks.count - 1, Int((max(start, end) * rate).rounded(.down)))
        guard first <= last else { return 0 }
        var peak: Float = 0
        for index in first...last {
            peak = max(peak, peaks[index])
        }
        return peak
    }

    /// Bar height (0–1) for a peak, on a decibel scale from -48 dB so quiet speech still
    /// shows.
    static func displayLevel(_ peak: Float) -> CGFloat {
        guard peak > 0 else { return 0 }
        let decibels = 20 * log10(Double(peak))
        return CGFloat(min(max((decibels + 48) / 48, 0), 1))
    }
}
