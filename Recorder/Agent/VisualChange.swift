import Foundation

/// How much of the screen changed by a moment of a recording.
struct VisualChangeSample: Equatable {
    /// Source seconds.
    var time: TimeInterval
    /// The fraction of the picture (0–1) that changed since the previous sample.
    var area: Double
}

/// Screen activity from small greyscale thumbnails. A recording only has frames where the
/// screen changed (ScreenCaptureKit sends nothing while it's still), so thumbnails are
/// only taken at frame times.
enum VisualChange {
    /// Thumbnails are this wide.
    static let thumbnailWidth = 160
    /// At most this many thumbnails per second of recording…
    static let sampleRate: Double = 4
    /// …and in all.
    static let maximumSamples = 1200
    /// Changing less than this much of the picture (a blinking caret, a clock) is still.
    static let minimumArea = 0.002

    /// The fraction of pixels whose brightness differs by more than `threshold` (of 255)
    /// between two thumbnails of the same size.
    static func changedArea(_ first: [UInt8], _ second: [UInt8], threshold: Int = 12) -> Double {
        guard !first.isEmpty, first.count == second.count else { return first.count == second.count ? 0 : 1 }
        var changed = 0
        for index in first.indices where abs(Int(first[index]) - Int(second[index])) > threshold {
            changed += 1
        }
        return Double(changed) / Double(first.count)
    }

    /// Which frames to take thumbnails of: the first in each slot of 1/`rate` seconds
    /// (slots widen for long takes so there are at most `limit`). Indices into
    /// `frameTimes`, which must be sorted.
    static func sampleIndices(
        frameTimes: [TimeInterval],
        duration: TimeInterval,
        rate: Double = VisualChange.sampleRate,
        limit: Int = VisualChange.maximumSamples
    ) -> [Int] {
        guard !frameTimes.isEmpty, rate > 0, limit > 0 else { return [] }
        let slot = max(1 / rate, duration / Double(limit))
        var indices: [Int] = []
        var lastSlot = -1
        for (index, time) in frameTimes.enumerated() {
            let slotIndex = Int((max(time, 0) / slot).rounded(.down))
            if slotIndex != lastSlot {
                indices.append(index)
                lastSlot = slotIndex
                if indices.count == limit {
                    break
                }
            }
        }
        return indices
    }

    /// Stretches where the screen keeps changing: samples that changed at least
    /// `minimumArea`, joined across gaps up to `joinGap`. A lone change lasts one slot.
    static func movingSpans(
        _ samples: [VisualChangeSample],
        minimumArea: Double = VisualChange.minimumArea,
        joinGap: TimeInterval = 0.6,
        slot: TimeInterval = 1 / VisualChange.sampleRate
    ) -> [TimeSpan] {
        var spans: [TimeSpan] = []
        for sample in samples.sorted(by: { $0.time < $1.time }) where sample.area >= minimumArea {
            let span = TimeSpan(start: sample.time, end: sample.time + slot)
            if let last = spans.last, span.start - last.end <= joinGap {
                spans[spans.count - 1].end = max(last.end, span.end)
            } else {
                spans.append(span)
            }
        }
        return spans
    }
}
