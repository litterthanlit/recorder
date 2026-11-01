import CoreGraphics
import Foundation

/// The crop following a window around a take: where it is at moments of the recording.
/// It keeps the crop's shape all along, so the canvas keeps its size; a window that grows
/// or shrinks makes the picture zoom out or in. Rects are normalized with a bottom-left
/// origin, like the crop.
struct CropPath: Codable, Equatable {
    struct Point: Codable, Equatable {
        /// Source seconds.
        var time: TimeInterval
        var rect: CGRect
    }

    /// In time order. Between two points the crop glides straight from one to the next;
    /// before the first and after the last it holds still.
    var points: [Point]
    /// The app whose window it follows.
    var app: String?

    /// Moves are smoothed over this long either side, so they ease in and out.
    static let smoothing: TimeInterval = 0.15
    /// A triangle of weights over -1…1 (times `smoothing`).
    private static let taps: [(offset: Double, weight: CGFloat)] = [
        (-1, 1), (-0.75, 2), (-0.5, 3), (-0.25, 4), (0, 5), (0.25, 4), (0.5, 3), (0.75, 2), (1, 1)
    ]

    init(points: [Point], app: String? = nil) {
        self.points = points
        self.app = app
    }

    /// Where the crop is at `time` (source seconds): the straight path between points,
    /// averaged over `smoothing` either side so it eases into and out of each move.
    func rect(at time: TimeInterval) -> CGRect {
        guard let first = points.first else { return SourceCrop.full }
        guard points.count > 1 else { return first.rect }
        var x: CGFloat = 0
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
        var total: CGFloat = 0
        for tap in Self.taps {
            let rect = straight(at: time + tap.offset * Self.smoothing)
            x += rect.minX * tap.weight
            y += rect.minY * tap.weight
            width += rect.width * tap.weight
            height += rect.height * tap.weight
            total += tap.weight
        }
        return CGRect(x: x / total, y: y / total, width: width / total, height: height / total)
    }

    /// The path without smoothing.
    func straight(at time: TimeInterval) -> CGRect {
        guard let first = points.first, let last = points.last else { return SourceCrop.full }
        guard time > first.time else { return first.rect }
        guard time < last.time else { return last.rect }
        // The last point at or before `time`.
        var low = 0
        var high = points.count
        while low < high {
            let middle = (low + high) / 2
            if points[middle].time <= time {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let from = points[max(low - 1, 0)]
        let to = points[min(low, points.count - 1)]
        let length = to.time - from.time
        guard length > 0 else { return to.rect }
        let progress = CGFloat((time - from.time) / length)
        return CGRect(
            x: from.rect.minX + (to.rect.minX - from.rect.minX) * progress,
            y: from.rect.minY + (to.rect.minY - from.rect.minY) * progress,
            width: from.rect.width + (to.rect.width - from.rect.width) * progress,
            height: from.rect.height + (to.rect.height - from.rect.height) * progress
        )
    }

    /// Points in time order with the shape `shape` (see `SourceCrop.fitted`), leaving out
    /// ones that aren't times or rects; `nil` when none are left.
    func sanitized(shape: CGFloat) -> CropPath? {
        let kept = points
            .filter { $0.time.isFinite }
            .compactMap { point in SourceCrop.fitted(point.rect, shape: shape).map { Point(time: point.time, rect: $0) } }
            .sorted { $0.time < $1.time }
        return kept.isEmpty ? nil : CropPath(points: kept, app: app)
    }
}

/// What the camera shows at rest over a take: the crop, where it is at each moment (it can
/// follow a window), or the whole recording.
struct CropMotion: Equatable {
    /// The crop when it holds still, or the whole recording.
    let rest: CGRect
    /// Where it moves; only with a crop.
    let path: CropPath?

    init(crop: CGRect?, path: CropPath? = nil) {
        let sanitized = crop.flatMap { SourceCrop.sanitized($0) }
        rest = sanitized ?? SourceCrop.full
        self.path = sanitized == nil || path?.points.isEmpty != false ? nil : path
    }

    /// Where the crop is at `time` (source seconds), with the shape of `rest`.
    func base(at time: TimeInterval) -> CGRect {
        guard let path, rest.width > 0 else { return rest }
        return SourceCrop.fitted(path.rect(at: time), shape: rest.height / rest.width) ?? rest
    }
}

/// A crop around an app's window that follows it over the take.
struct WindowCrop: Equatable {
    /// The window at its most usual size and place: the crop at rest. `nil` when the
    /// window filled the recording.
    var crop: CGRect?
    /// Where the crop moves with the window; `nil` when it never moved.
    var path: CropPath?
    /// How many times the window moved (a drag counts once).
    var moves: Int

    /// A glide to where the window is next lasts this long, ending when it was seen
    /// there…
    static let glide: TimeInterval = 0.35
    /// …unless it was seen moving (two places this close together in time), which the
    /// crop then follows straight.
    static let movingGap: TimeInterval = 0.3
    /// A window smaller than the usual one isn't blown up past this (of the usual size).
    static let minimumScale: CGFloat = 0.6
    /// Sizes this close (of the recording) count as one.
    static let sizeTolerance: CGFloat = 0.01

    /// Where `app`'s front window was over the take (`events`), as a crop with the
    /// path that moves it; `nil` when the window never showed in the recording.
    static func following(_ app: String, in events: [AppFocusEvent], duration: TimeInterval) -> WindowCrop? {
        let sorted = events.sorted { $0.timestamp < $1.timestamp }
        let seen: [(time: TimeInterval, rect: CGRect)] = sorted.compactMap { event in
            guard event.isApp(app), let rect = event.windowRect, rect.width > 0, rect.height > 0 else { return nil }
            return (max(event.timestamp, 0), rect)
        }
        guard let firstSeen = seen.first else { return nil }

        // How long each place lasted, until the window was seen elsewhere.
        var held: [TimeInterval] = []
        for (index, place) in seen.enumerated() {
            let until = index + 1 < seen.count ? seen[index + 1].time : max(duration, place.time)
            held.append(max(until - place.time, 0))
        }
        // The most usual size, then the place it held longest at that size.
        var sizes: [(size: CGSize, seconds: TimeInterval)] = []
        for (place, seconds) in zip(seen, held) {
            if let index = sizes.firstIndex(where: { sameSize($0.size, place.rect.size) }) {
                sizes[index].seconds += seconds
            } else {
                sizes.append((place.rect.size, seconds))
            }
        }
        let usual = sizes.max { $0.seconds < $1.seconds }?.size ?? firstSeen.rect.size
        var home = firstSeen.rect
        var longest = -1.0
        for (place, seconds) in zip(seen, held) where sameSize(place.rect.size, usual) && seconds > longest {
            home = place.rect
            longest = seconds
        }
        guard let crop = SourceCrop.sanitized(home) else {
            return WindowCrop(crop: nil, path: nil, moves: 0)
        }

        let shape = crop.height / crop.width
        let smallest = crop.width * minimumScale
        func framed(_ window: CGRect) -> CGRect {
            var rect = SourceCrop.fitted(window, shape: shape) ?? crop
            if rect.width < smallest {
                rect = SourceCrop.fitted(
                    CGRect(x: window.midX - smallest / 2, y: window.midY - smallest * shape / 2, width: smallest, height: smallest * shape),
                    shape: shape
                ) ?? rect
            }
            return rect
        }

        var points = [CropPath.Point(time: firstSeen.time, rect: framed(firstSeen.rect))]
        var moves = 0
        for index in seen.indices.dropFirst() {
            let rect = framed(seen[index].rect)
            guard let last = points.last, !AppFocusTimeline.sameWindow(rect, last.rect) else { continue }
            let time = seen[index].time
            let previous = seen[index - 1].time
            let moving = time - previous <= movingGap
            let start = max(moving ? previous : time - glide, last.time)
            if start > last.time + 1e-6 {
                points.append(CropPath.Point(time: start, rect: last.rect))
            }
            points.append(CropPath.Point(time: time, rect: rect))
            if !moving {
                moves += 1
            }
        }
        let path = points.count > 1 ? CropPath(points: points, app: sorted.first { $0.isApp(app) }?.appName ?? app) : nil
        return WindowCrop(crop: crop, path: path, moves: path == nil ? 0 : max(moves, 1))
    }

    private static func sameSize(_ first: CGSize, _ second: CGSize) -> Bool {
        abs(first.width - second.width) < sizeTolerance && abs(first.height - second.height) < sizeTolerance
    }
}
