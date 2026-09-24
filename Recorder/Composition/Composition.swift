import Foundation

/// A source interval placed on the composition timeline.
/// Phase 1 uses a single clip; Phase 2 overlaps clips for crossfades.
struct TimelineClip: Codable, Equatable, Identifiable {
    var id: UUID
    var sourcePath: String
    var sourceIn: TimeInterval
    var sourceOut: TimeInterval
    var compositionStart: TimeInterval
    var speed: Double

    var sourceURL: URL {
        URL(fileURLWithPath: sourcePath)
    }

    var sourceDuration: TimeInterval {
        max(0, sourceOut - sourceIn)
    }

    var compositionDuration: TimeInterval {
        sourceDuration / max(speed, 0.0001)
    }

    var compositionEnd: TimeInterval {
        compositionStart + compositionDuration
    }

    init(
        id: UUID = UUID(),
        sourcePath: String,
        sourceIn: TimeInterval,
        sourceOut: TimeInterval,
        compositionStart: TimeInterval = 0,
        speed: Double = 1
    ) {
        self.id = id
        self.sourcePath = sourcePath
        self.sourceIn = sourceIn
        self.sourceOut = sourceOut
        self.compositionStart = compositionStart
        self.speed = speed
    }

    func contains(compositionTime time: TimeInterval) -> Bool {
        time >= compositionStart && time <= compositionEnd
    }

    func sourceTime(forCompositionTime time: TimeInterval) -> TimeInterval? {
        guard contains(compositionTime: time) else { return nil }
        let elapsed = time - compositionStart
        return sourceIn + elapsed * speed
    }
}

/// Resolves composition seconds to a clip and source timestamp.
/// When clips overlap (future crossfades), the last matching clip wins for
/// the primary sample; the renderer can still query neighbors separately.
struct CompositionTimeMap: Equatable {
    var clips: [TimelineClip]

    var duration: TimeInterval {
        clips.map(\.compositionEnd).max() ?? 0
    }

    func resolve(compositionTime: TimeInterval) -> (clip: TimelineClip, sourceTime: TimeInterval)? {
        let matches = clips.compactMap { clip -> (TimelineClip, TimeInterval)? in
            guard let sourceTime = clip.sourceTime(forCompositionTime: compositionTime) else {
                return nil
            }
            return (clip, sourceTime)
        }
        guard let last = matches.last else { return nil }
        return (last.0, last.1)
    }

    func overlappingClips(at compositionTime: TimeInterval) -> [TimelineClip] {
        clips.filter { $0.contains(compositionTime: compositionTime) }
    }
}

enum CompositionFactory {
    static func singleClip(
        sourcePath: String,
        sourceIn: TimeInterval,
        sourceOut: TimeInterval
    ) -> CompositionTimeMap {
        CompositionTimeMap(
            clips: [
                TimelineClip(
                    sourcePath: sourcePath,
                    sourceIn: sourceIn,
                    sourceOut: sourceOut,
                    compositionStart: 0,
                    speed: 1
                )
            ]
        )
    }
}

/// Output clock for export.
///
/// ScreenCaptureKit only delivers a frame when the screen changes, so the source is
/// variable frame rate with long gaps during still moments. Exporting one output frame
/// per source frame would sample zoom, cursor, and ripple animation only at those
/// irregular moments (zooms snap, the cursor teleports, still endings disappear).
/// Instead the export runs on this fixed clock and each output frame shows the most
/// recent source frame at or before its time, which is what a player would display.
struct ConstantFrameRateTimeline: Equatable {
    let frameRate: Int
    /// Output duration in seconds (the trimmed length).
    let duration: TimeInterval
    /// Source time that output time zero corresponds to (the trim start).
    let sourceStart: TimeInterval

    /// Timestamps within this distance count as equal, absorbing rounding in PTS math.
    static let tolerance: TimeInterval = 0.0005

    init(frameRate: Int, duration: TimeInterval, sourceStart: TimeInterval) {
        self.frameRate = max(1, frameRate)
        self.duration = max(0, duration)
        self.sourceStart = sourceStart
    }

    /// Frames at 0, 1/fps, 2/fps, … strictly before `duration`, and at least one frame
    /// for any non-empty range.
    var frameCount: Int {
        guard duration > 0 else { return 0 }
        let exact = duration * Double(frameRate)
        return max(1, Int((exact - Self.tolerance * Double(frameRate)).rounded(.up)))
    }

    func outputTime(forFrame index: Int) -> TimeInterval {
        Double(index) / Double(frameRate)
    }

    func sourceTime(forFrame index: Int) -> TimeInterval {
        sourceStart + outputTime(forFrame: index)
    }

    /// Whether a source frame presented at `nextSourceTime` should replace the held frame
    /// when rendering the output frame for `sourceTime`.
    static func shouldAdvance(to nextSourceTime: TimeInterval, forSourceTime sourceTime: TimeInterval) -> Bool {
        nextSourceTime <= sourceTime + tolerance
    }

    /// For each output frame, the index of the source frame to show (sorted source
    /// times). Before the first source frame, the first frame is shown.
    func heldSourceFrameIndices(sourceTimes: [TimeInterval]) -> [Int] {
        guard !sourceTimes.isEmpty else { return [] }
        var held = 0
        return (0..<frameCount).map { frame in
            let time = sourceTime(forFrame: frame)
            while held + 1 < sourceTimes.count,
                  Self.shouldAdvance(to: sourceTimes[held + 1], forSourceTime: time) {
                held += 1
            }
            return held
        }
    }
}
