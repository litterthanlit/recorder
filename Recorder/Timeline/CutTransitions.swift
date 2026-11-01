import Foundation

/// How the picture moves across a cut.
enum CutTransitionStyle: String, Codable, CaseIterable, Identifiable {
    /// Pushes in with a zoom blur, landing on the next shot.
    case zoomBlur = "zoom_blur"
    /// A fast sideways whip pan.
    case whip
    /// Blurs and dims for a moment.
    case blurDip = "blur_dip"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .zoomBlur: return "Zoom"
        case .whip: return "Whip"
        case .blurDip: return "Blur"
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CutTransitionStyle(rawValue: raw) ?? .zoomBlur
    }
}

/// A transition at every cut (where the edit jumps over removed time).
struct CutTransition: Codable, Equatable {
    var style: CutTransitionStyle = .zoomBlur
    /// How long it lasts, centred on the cut (output seconds).
    var duration: TimeInterval = 0.4

    static let durationRange: ClosedRange<TimeInterval> = 0.15...1

    init(style: CutTransitionStyle = .zoomBlur, duration: TimeInterval = 0.4) {
        self.style = style
        self.duration = min(max(duration, Self.durationRange.lowerBound), Self.durationRange.upperBound)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let style = (try? container.decodeIfPresent(CutTransitionStyle.self, forKey: .style)) ?? .zoomBlur
        let duration = (try? container.decodeIfPresent(TimeInterval.self, forKey: .duration)) ?? 0.4
        self.init(style: style, duration: duration.isFinite ? duration : 0.4)
    }

    private enum CodingKeys: String, CodingKey {
        case style, duration
    }
}

/// Where a transition is at a moment.
struct CutTransitionState: Equatable {
    /// −1 where the transition starts, 0 at the cut, 1 where it ends.
    var progress: Double
    /// 0…1, strongest at the cut.
    var intensity: Double
}

enum CutTransitions {
    /// Output times of the cuts: where one segment ends and the next starts later in the
    /// recording.
    static func cutTimes(in timeline: EditTimeline) -> [TimeInterval] {
        let segments = timeline.segments
        let starts = timeline.outputStarts
        var times: [TimeInterval] = []
        for index in segments.indices.dropFirst() where segments[index].source.start - segments[index - 1].source.end > 1e-6 {
            times.append(starts[index])
        }
        return times
    }

    /// The transition at output time `time`, for the nearest of `cuts` (sorted), or `nil`
    /// away from them.
    static func state(atOutput time: TimeInterval, cuts: [TimeInterval], duration: TimeInterval) -> CutTransitionState? {
        let half = duration / 2
        guard half > 0, let nearest = cuts.min(by: { abs($0 - time) < abs($1 - time) }), abs(time - nearest) < half else {
            return nil
        }
        let progress = (time - nearest) / half
        return CutTransitionState(progress: progress, intensity: (1 + cos(Double.pi * progress)) / 2)
    }
}
