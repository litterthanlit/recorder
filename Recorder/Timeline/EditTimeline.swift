import Foundation

/// A stretch of time, `start` inclusive, `end` exclusive.
struct TimeSpan: Codable, Hashable {
    var start: TimeInterval
    var end: TimeInterval

    var duration: TimeInterval {
        max(0, end - start)
    }

    func contains(_ time: TimeInterval) -> Bool {
        time >= start && time < end
    }

    func intersection(_ other: TimeSpan) -> TimeSpan? {
        let span = TimeSpan(start: max(start, other.start), end: min(end, other.end))
        return span.end > span.start ? span : nil
    }
}

/// A kept piece of the recording, played at `speed`.
struct EditSegment: Codable, Equatable, Identifiable {
    var id: UUID
    /// Source seconds (the recording's own timeline).
    var source: TimeSpan
    var speed: Double

    init(id: UUID = UUID(), source: TimeSpan, speed: Double = 1) {
        self.id = id
        self.source = source
        self.speed = speed
    }

    /// How long the segment lasts in the edited video.
    var outputDuration: TimeInterval {
        source.duration / speed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        source = try container.decode(TimeSpan.self, forKey: .source)
        speed = try container.decodeIfPresent(Double.self, forKey: .speed) ?? 1
    }

    private enum CodingKeys: String, CodingKey {
        case id, source, speed
    }
}

/// The edit: which parts of the recording are kept, in order, and how fast each plays.
///
/// There are two clocks. *Source time* is the recording's own (t = 0 at the first frame);
/// clicks, the cursor, zooms, text and blur regions all live there, so they stay attached
/// to what's on screen when the edit changes. *Output time* is the edited video's. This
/// type is the only place that converts between them.
///
/// Segments are sorted, don't overlap, and are never reordered, so source time only
/// moves forward as output time does: the exporter can read the recording once, in order.
struct EditTimeline: Codable, Equatable {
    private(set) var segments: [EditSegment]
    /// Ease into and out of sped-up parts over up to this long (output seconds) instead
    /// of jumping speed; `nil` jumps. See `SpeedRamp`.
    var speedRamp: TimeInterval?

    static let speedRange: ClosedRange<Double> = 0.25...16
    /// Pieces shorter than this (source seconds) aren't kept.
    static let minimumSegmentDuration: TimeInterval = 1.0 / 30.0

    /// The whole recording at normal speed.
    init(sourceDuration: TimeInterval) {
        segments = [EditSegment(source: TimeSpan(start: 0, end: max(0, sourceDuration)))]
    }

    /// `segments` cleaned up: sorted, overlaps removed, speeds clamped, tiny pieces dropped.
    init(segments: [EditSegment], sourceDuration: TimeInterval) {
        self.segments = segments
        self = normalized(sourceDuration: sourceDuration)
    }

    /// A project from before cuts existed: its head and tail trim.
    static func legacy(trimStart: TimeInterval, trimEnd: TimeInterval?, sourceDuration: TimeInterval) -> EditTimeline {
        let end = min(trimEnd ?? sourceDuration, sourceDuration)
        return EditTimeline(
            segments: [EditSegment(source: TimeSpan(start: max(0, trimStart), end: end))],
            sourceDuration: sourceDuration
        )
    }

    // MARK: - Measurements

    var outputDuration: TimeInterval {
        segments.reduce(0) { $0 + $1.outputDuration }
    }

    /// First kept source time (the head trim).
    var trimStart: TimeInterval {
        segments.first?.source.start ?? 0
    }

    /// Last kept source time (the tail trim).
    var trimEnd: TimeInterval {
        segments.last?.source.end ?? 0
    }

    var hasCuts: Bool {
        zip(segments, segments.dropFirst()).contains { $1.source.start - $0.source.end > 1e-9 }
    }

    var hasSpeedChanges: Bool {
        segments.contains { abs($0.speed - 1) > 1e-9 }
    }

    /// Where each segment starts in output time.
    var outputStarts: [TimeInterval] {
        var starts: [TimeInterval] = []
        var time: TimeInterval = 0
        for segment in segments {
            starts.append(time)
            time += segment.outputDuration
        }
        return starts
    }

    /// Where each segment sits in output time.
    var outputSpans: [TimeSpan] {
        zip(segments, outputStarts).map { segment, start in
            TimeSpan(start: start, end: start + segment.outputDuration)
        }
    }

    /// The segment playing at output time `time` (the last one at the very end).
    func segmentIndex(atOutput time: TimeInterval) -> Int? {
        guard !segments.isEmpty else { return nil }
        let starts = outputStarts
        for index in segments.indices.reversed() where time >= starts[index] - 1e-12 {
            return index
        }
        return 0
    }

    // MARK: - Mapping

    /// Whether sped-up parts ease in and out.
    var hasSpeedRamps: Bool {
        (speedRamp ?? 0) > 0
    }

    /// The constant-speed pieces segment `index` plays as: itself, unless it ramps.
    func pieces(ofSegment index: Int) -> [SpeedPiece] {
        if let speedRamp, speedRamp > 0 {
            return SpeedRamp.pieces(of: segments, at: index, ramp: speedRamp)
        }
        let segment = segments[index]
        return [SpeedPiece(source: segment.source, outputOffset: 0, outputDuration: segment.outputDuration, speed: segment.speed)]
    }

    /// How far into segment `index` source time `time` plays (output seconds).
    private func outputOffset(inSegment index: Int, forSource time: TimeInterval) -> TimeInterval {
        let segment = segments[index]
        if hasSpeedRamps {
            return SpeedRamp.outputOffset(forSource: time, in: pieces(ofSegment: index))
        }
        return (time - segment.source.start) / segment.speed
    }

    /// The source time shown at output time `time` (clamped to the edit). At a cut it's
    /// the start of the later segment. Never decreases as `time` increases.
    func sourceTime(forOutput time: TimeInterval) -> TimeInterval {
        guard let index = segmentIndex(atOutput: time) else { return 0 }
        let segment = segments[index]
        let start = outputStarts[index]
        let offset = min(max(time - start, 0), segment.outputDuration)
        if hasSpeedRamps {
            return SpeedRamp.sourceTime(forOffset: offset, in: pieces(ofSegment: index))
        }
        return segment.source.start + offset * segment.speed
    }

    /// Where source time `time` appears in the edit, or `nil` if it was cut.
    func outputTime(forSource time: TimeInterval) -> TimeInterval? {
        let starts = outputStarts
        for (index, segment) in segments.enumerated() {
            if segment.source.contains(time) {
                return starts[index] + outputOffset(inSegment: index, forSource: time)
            }
        }
        if let last = segments.last, abs(time - last.source.end) < 1e-9 {
            return outputDuration
        }
        return nil
    }

    /// Like `outputTime(forSource:)`, but a cut time moves to where the edit continues.
    func outputTimeClamped(forSource time: TimeInterval) -> TimeInterval {
        if let output = outputTime(forSource: time) {
            return output
        }
        let starts = outputStarts
        for (index, segment) in segments.enumerated() where time < segment.source.start {
            return starts[index]
        }
        return outputDuration
    }

    /// The parts of source span `span` that are kept, as output spans (merged where they
    /// run on across a split).
    func outputSpans(forSource span: TimeSpan) -> [TimeSpan] {
        var result: [TimeSpan] = []
        let starts = outputStarts
        for (index, segment) in segments.enumerated() {
            guard let kept = segment.source.intersection(span) else { continue }
            let start = starts[index] + outputOffset(inSegment: index, forSource: kept.start)
            let end = starts[index] + outputOffset(inSegment: index, forSource: kept.end)
            if let last = result.last, abs(last.end - start) < 1e-9 {
                result[result.count - 1].end = end
            } else {
                result.append(TimeSpan(start: start, end: end))
            }
        }
        return result
    }

    /// Everything a composition needs: each constant-speed piece's source span, where it
    /// starts in the output and how long it lasts there (one piece per segment without
    /// speed ramps).
    var compositionPlan: [(source: TimeSpan, outputStart: TimeInterval, outputDuration: TimeInterval, speed: Double)] {
        guard hasSpeedRamps else {
            return zip(segments, outputStarts).map { segment, start in
                (segment.source, start, segment.outputDuration, segment.speed)
            }
        }
        var plan: [(source: TimeSpan, outputStart: TimeInterval, outputDuration: TimeInterval, speed: Double)] = []
        for (index, start) in outputStarts.enumerated() {
            for piece in pieces(ofSegment: index) {
                plan.append((piece.source, start + piece.outputOffset, piece.outputDuration, piece.speed))
            }
        }
        return plan
    }

    // MARK: - Editing

    /// Splits the segment at output time `time`. Refused (false) at a segment's edge,
    /// where one side would be too short to keep.
    @discardableResult
    mutating func split(atOutput time: TimeInterval) -> Bool {
        guard let index = segmentIndex(atOutput: time) else { return false }
        let segment = segments[index]
        let splitTime = sourceTime(forOutput: time)
        guard splitTime - segment.source.start >= Self.minimumSegmentDuration,
              segment.source.end - splitTime >= Self.minimumSegmentDuration
        else { return false }
        var first = segment
        first.source.end = splitTime
        let second = EditSegment(source: TimeSpan(start: splitTime, end: segment.source.end), speed: segment.speed)
        segments.replaceSubrange(index...index, with: [first, second])
        return true
    }

    /// Removes a segment; what follows moves up (a ripple delete). The last one stays.
    @discardableResult
    mutating func deleteSegment(id: UUID) -> Bool {
        guard segments.count > 1, let index = segments.firstIndex(where: { $0.id == id }) else { return false }
        segments.remove(at: index)
        return true
    }

    mutating func setSpeed(_ speed: Double, forSegment id: UUID) {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[index].speed = Self.clampSpeed(speed)
    }

    /// Moves a segment's start (in source time). It can grow back into cut material up to
    /// the previous segment, and can't shrink below the minimum.
    mutating func setSourceStart(_ time: TimeInterval, forSegment id: UUID) {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        let lower = index > 0 ? segments[index - 1].source.end : 0
        let upper = segments[index].source.end - Self.minimumSegmentDuration
        segments[index].source.start = min(max(time, lower), upper)
    }

    /// Moves a segment's end (in source time), up to the next segment or the end of the
    /// recording.
    mutating func setSourceEnd(_ time: TimeInterval, forSegment id: UUID, sourceDuration: TimeInterval) {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        let lower = segments[index].source.start + Self.minimumSegmentDuration
        let upper = index + 1 < segments.count ? segments[index + 1].source.start : sourceDuration
        segments[index].source.end = max(min(time, upper), lower)
    }

    /// The head trim: where the first segment starts.
    mutating func setTrimStart(_ time: TimeInterval) {
        guard let first = segments.first else { return }
        setSourceStart(time, forSegment: first.id)
    }

    /// The tail trim: where the last segment ends.
    mutating func setTrimEnd(_ time: TimeInterval, sourceDuration: TimeInterval) {
        guard let last = segments.last else { return }
        setSourceEnd(time, forSegment: last.id, sourceDuration: sourceDuration)
    }

    /// Cuts source span `span` out of the edit. Refused (false) if nothing would be left.
    @discardableResult
    mutating func excludeSource(_ span: TimeSpan) -> Bool {
        var result: [EditSegment] = []
        for segment in segments {
            guard let overlap = segment.source.intersection(span) else {
                result.append(segment)
                continue
            }
            if overlap.start - segment.source.start >= Self.minimumSegmentDuration {
                var before = segment
                before.source.end = overlap.start
                result.append(before)
            }
            if segment.source.end - overlap.end >= Self.minimumSegmentDuration {
                let after = EditSegment(source: TimeSpan(start: overlap.end, end: segment.source.end), speed: segment.speed)
                result.append(after)
            }
        }
        guard !result.isEmpty else { return false }
        segments = result
        return true
    }

    /// Plays source span `span` at `speed`, splitting segments at its edges.
    mutating func applySpeed(_ speed: Double, toSource span: TimeSpan) {
        let speed = Self.clampSpeed(speed)
        var result: [EditSegment] = []
        for segment in segments {
            guard let overlap = segment.source.intersection(span) else {
                result.append(segment)
                continue
            }
            // Don't leave slivers: an edge within the minimum of the segment's own edge
            // snaps to it.
            let start = overlap.start - segment.source.start < Self.minimumSegmentDuration ? segment.source.start : overlap.start
            let end = segment.source.end - overlap.end < Self.minimumSegmentDuration ? segment.source.end : overlap.end
            let coversSegment = start == segment.source.start && end == segment.source.end
            guard end - start >= Self.minimumSegmentDuration || coversSegment else {
                // Too short a piece to split off: leave the segment as it is.
                result.append(segment)
                continue
            }
            if start > segment.source.start {
                var before = segment
                before.source.end = start
                result.append(before)
            }
            result.append(EditSegment(
                id: start == segment.source.start ? segment.id : UUID(),
                source: TimeSpan(start: start, end: end),
                speed: speed
            ))
            if end < segment.source.end {
                let after = EditSegment(source: TimeSpan(start: end, end: segment.source.end), speed: segment.speed)
                result.append(after)
            }
        }
        segments = result
    }

    /// Clamped to the recording, sorted, without overlaps or slivers, speeds in range, and
    /// never empty.
    func normalized(sourceDuration: TimeInterval) -> EditTimeline {
        let duration = max(0, sourceDuration)
        var cleaned: [EditSegment] = []
        for var segment in segments.sorted(by: { $0.source.start < $1.source.start }) {
            segment.source.start = min(max(segment.source.start, 0), duration)
            segment.source.end = min(max(segment.source.end, 0), duration)
            if let previous = cleaned.last, segment.source.start < previous.source.end {
                segment.source.start = previous.source.end
            }
            segment.speed = Self.clampSpeed(segment.speed)
            guard segment.source.duration >= Self.minimumSegmentDuration else { continue }
            cleaned.append(segment)
        }
        var copy = self
        copy.segments = cleaned.isEmpty ? [EditSegment(source: TimeSpan(start: 0, end: duration))] : cleaned
        return copy
    }

    static func clampSpeed(_ speed: Double) -> Double {
        guard speed.isFinite else { return 1 }
        return min(max(speed, speedRange.lowerBound), speedRange.upperBound)
    }

    // MARK: - Coding

    private enum CodingKeys: String, CodingKey {
        case segments, speedRamp
    }

    /// Ramps longer than this are taken as this.
    static let maximumSpeedRamp: TimeInterval = 2

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        segments = try container.decode([EditSegment].self, forKey: .segments)
        let ramp = try? container.decodeIfPresent(TimeInterval.self, forKey: .speedRamp)
        speedRamp = ramp.flatMap { $0.isFinite && $0 > 0 ? min($0, Self.maximumSpeedRamp) : nil }
    }
}
