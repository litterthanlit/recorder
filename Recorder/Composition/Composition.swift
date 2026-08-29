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
