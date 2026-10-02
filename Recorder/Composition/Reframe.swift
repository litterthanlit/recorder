import CoreGraphics
import Foundation

/// The video recomposed for another shape: a crop of the canvas's shape inside what the
/// video shows (the app's window, or the whole recording) that follows the action, the
/// way a camera operator reframes a wide shot for a tall screen, instead of shrinking the
/// picture onto a background. Rects are normalized with a bottom-left origin.
struct Reframing: Codable, Equatable {
    /// The canvas shape it was made for; it applies only while the canvas has that shape.
    var aspect: OutputAspect
    /// Where it rests, with the canvas's shape.
    var crop: CGRect
    /// Where it moves with the action; `nil` holds still.
    var path: CropPath?

    /// The same with `crop` and `path` kept inside the recording and with `crop`'s shape;
    /// `nil` when `crop` isn't one.
    func sanitized() -> Reframing? {
        guard aspect != .auto, let rest = SourceCrop.sanitized(crop) else { return nil }
        return Reframing(aspect: aspect, crop: rest, path: path.flatMap { $0.sanitized(shape: rest.height / rest.width) })
    }
}

/// Something worth looking at, at a moment of the recording.
struct AttentionPoint: Equatable {
    /// Source seconds.
    var time: TimeInterval
    /// Normalized, bottom-left origin.
    var point: CGPoint
    var weight: Double
}

/// Works out a reframing from where the action is over the take.
enum Reframer {
    /// How often the frame is worked out, in seconds.
    static let step: TimeInterval = 0.1
    /// Action counts this long either side of a moment (a Gaussian's sigma), so the frame
    /// sets off a little before it.
    static let reach: TimeInterval = 0.6
    /// The frame lets the action wander this far from where it's aimed (of the frame's
    /// size) before it moves…
    static let deadZone: CGFloat = 0.2
    /// …and then gets there in about this long, without overshooting.
    static let settle: TimeInterval = 0.8
    /// Shapes this close (relative) need no reframing.
    static let shapeTolerance: CGFloat = 0.02

    static let clickWeight = 1.0
    static let typingWeight = 0.6
    static let cursorWeight = 0.15
    static let zoomWeight = 2.0

    /// What to follow: clicks, typing (where the last click was), the pointer, and zooms
    /// while they hold. Clicks and the pointer are in source pixels (bottom-left origin);
    /// zoom centres are normalized.
    static func attention(
        clicks: [ClickEvent],
        keystrokes: [KeystrokeEvent],
        cursor: [CursorEvent],
        zooms: [ZoomKeyframe],
        sourceSize: CGSize
    ) -> [AttentionPoint] {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return [] }
        func normalized(_ point: CGPoint) -> CGPoint {
            CGPoint(x: min(max(point.x / sourceSize.width, 0), 1), y: min(max(point.y / sourceSize.height, 0), 1))
        }
        var result: [AttentionPoint] = []
        let sortedClicks = clicks.sorted { $0.timestamp < $1.timestamp }
        for click in sortedClicks {
            result.append(AttentionPoint(time: click.timestamp, point: normalized(click.location), weight: clickWeight))
        }
        // Typing goes where the last click was.
        var clickIndex = 0
        var lastClick: CGPoint?
        for key in keystrokes.sorted(by: { $0.timestamp < $1.timestamp }) {
            while clickIndex < sortedClicks.count, sortedClicks[clickIndex].timestamp <= key.timestamp {
                lastClick = normalized(sortedClicks[clickIndex].location)
                clickIndex += 1
            }
            if let lastClick {
                result.append(AttentionPoint(time: key.timestamp, point: lastClick, weight: typingWeight))
            }
        }
        // The pointer, a few times a second.
        var lastSample = -Double.infinity
        for event in cursor.sorted(by: { $0.timestamp < $1.timestamp }) where event.timestamp - lastSample >= step {
            lastSample = event.timestamp
            result.append(AttentionPoint(time: event.timestamp, point: normalized(event.location), weight: cursorWeight))
        }
        // A zoom says where to look for as long as it holds.
        for zoom in zooms where zoom.endTime > zoom.peakTime {
            var time = zoom.peakTime
            while time <= zoom.endTime {
                result.append(AttentionPoint(time: time, point: zoom.center, weight: zoomWeight))
                time += step
            }
        }
        return result.sorted { $0.time < $1.time }
    }

    /// A reframing for a canvas of `aspect` showing `shown` (the crop over the take) of a
    /// recording of `source` pixels, following `attention`; `nil` when the picture already
    /// has that shape.
    static func reframe(
        aspect: OutputAspect,
        source: CGSize,
        shown: CropMotion,
        attention: [AttentionPoint],
        duration: TimeInterval
    ) -> Reframing? {
        guard let ratio = aspect.ratio, ratio > 0, source.width > 0, source.height > 0 else { return nil }
        // Height over width of the canvas's shape, in normalized units.
        let shape = (source.width / source.height) / ratio
        let rest = shown.rest
        guard rest.width > 0, abs(rest.height / rest.width - shape) / shape > shapeTolerance else { return nil }

        let count = max(1, Int((max(duration, 0) / step).rounded(.up)) + 1)
        let desired = smoothedAttention(attention, count: count)

        // A critically damped camera chasing a goal that only moves when the action
        // leaves the dead zone around it.
        let omega = 4.5 / settle
        var center = desired.first(where: { $0 != nil }).flatMap { $0 } ?? CGPoint(x: rest.midX, y: rest.midY)
        var goal = center
        var velocity = CGVector(dx: 0, dy: 0)
        var rects: [CGRect] = []
        rects.reserveCapacity(count)
        for index in 0..<count {
            let time = Double(index) * step
            let container = shown.base(at: time)
            let size = frameSize(in: container, shape: shape)
            if let target = desired[index] {
                if abs(target.x - goal.x) > deadZone * size.width {
                    goal.x = target.x
                }
                if abs(target.y - goal.y) > deadZone * size.height {
                    goal.y = target.y
                }
            }
            if index > 0 {
                velocity.dx += (omega * omega * (goal.x - center.x) - 2 * omega * velocity.dx) * step
                velocity.dy += (omega * omega * (goal.y - center.y) - 2 * omega * velocity.dy) * step
                center.x += velocity.dx * step
                center.y += velocity.dy * step
            }
            // Keep the frame inside what's shown.
            let lowX = container.minX + size.width / 2
            let highX = container.maxX - size.width / 2
            let lowY = container.minY + size.height / 2
            let highY = container.maxY - size.height / 2
            if center.x < lowX || center.x > highX {
                center.x = min(max(center.x, lowX), max(highX, lowX))
                velocity.dx = 0
            }
            if center.y < lowY || center.y > highY {
                center.y = min(max(center.y, lowY), max(highY, lowY))
                velocity.dy = 0
            }
            goal.x = min(max(goal.x, lowX), max(highX, lowX))
            goal.y = min(max(goal.y, lowY), max(highY, lowY))
            rects.append(CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height))
        }

        // Keep where it moves and where still stretches start and end.
        var points: [CropPath.Point] = []
        for (index, rect) in rects.enumerated() {
            let changedIn = index == 0 || !same(rect, rects[index - 1])
            let changesOut = index == rects.count - 1 || !same(rect, rects[index + 1])
            if changedIn || changesOut {
                points.append(CropPath.Point(time: Double(index) * step, rect: rect))
            }
        }
        let resting = rects[rects.count / 2]
        let moves = points.count > 1 && points.contains { !same($0.rect, points[0].rect) }
        return Reframing(aspect: aspect, crop: resting, path: moves ? CropPath(points: points) : nil).sanitized()
    }

    /// The biggest rect of `shape` (height over width) that fits `container`.
    static func frameSize(in container: CGRect, shape: CGFloat) -> CGSize {
        if container.height >= container.width * shape {
            return CGSize(width: container.width, height: container.width * shape)
        }
        return CGSize(width: container.height / shape, height: container.height)
    }

    /// Where the action is at each step (`nil` where there's none near), weighted and
    /// spread over `reach`.
    static func smoothedAttention(_ attention: [AttentionPoint], count: Int) -> [CGPoint?] {
        var sumX = [Double](repeating: 0, count: count)
        var sumY = [Double](repeating: 0, count: count)
        var sumWeight = [Double](repeating: 0, count: count)
        for point in attention where point.weight > 0 {
            let index = Int((point.time / step).rounded())
            guard index >= 0, index < count else { continue }
            sumX[index] += Double(point.point.x) * point.weight
            sumY[index] += Double(point.point.y) * point.weight
            sumWeight[index] += point.weight
        }
        let radius = Int((3 * reach / step).rounded(.up))
        let kernel = (0...radius).map { offset -> Double in
            let seconds = Double(offset) * step
            return exp(-0.5 * (seconds / reach) * (seconds / reach))
        }
        var result = [CGPoint?](repeating: nil, count: count)
        for index in 0..<count {
            var x = 0.0
            var y = 0.0
            var weight = 0.0
            for offset in -radius...radius {
                let other = index + offset
                guard other >= 0, other < count, sumWeight[other] > 0 else { continue }
                let factor = kernel[abs(offset)]
                x += sumX[other] * factor
                y += sumY[other] * factor
                weight += sumWeight[other] * factor
            }
            // Faint, far-off action doesn't count.
            if weight > 0.05 {
                result[index] = CGPoint(x: x / weight, y: y / weight)
            }
        }
        return result
    }

    private static func same(_ first: CGRect, _ second: CGRect) -> Bool {
        abs(first.minX - second.minX) < 1e-4 && abs(first.minY - second.minY) < 1e-4
            && abs(first.width - second.width) < 1e-4 && abs(first.height - second.height) < 1e-4
    }
}

extension ProjectEditSettings {
    /// The reframing in use: the one made for the canvas's shape, if there is one.
    var activeReframe: Reframing? {
        reframe.flatMap { $0.aspect == canvas.aspect ? $0 : nil }
    }

    /// What the video shows: the reframing for the canvas's shape, or the crop.
    var shownCrop: CGRect? {
        activeReframe?.crop ?? sourceCrop
    }

    /// Where what's shown moves.
    var shownCropPath: CropPath? {
        if let activeReframe {
            return activeReframe.path
        }
        return cropPath
    }
}

extension Reframer {
    /// The reframing for `settings`'s canvas shape, picked from its crop (the window, or
    /// the whole recording) and following the take's action and `keyframes`' zooms; `nil`
    /// when the picture already has that shape.
    static func reframe(_ settings: ProjectEditSettings, keyframes: [ZoomKeyframe], take: AgentEditTake) -> Reframing? {
        let action = attention(
            clicks: take.clicks,
            keystrokes: take.keystrokes,
            cursor: take.cursor,
            zooms: keyframes,
            sourceSize: take.sourceSize
        )
        return reframe(
            aspect: settings.canvas.aspect,
            source: take.sourceSize,
            shown: settings.windowMotion,
            attention: action,
            duration: take.duration
        )
    }
}

extension EditorSnapshot {
    /// Keeps the reframing in step: worked out again when the canvas reframes and what it
    /// follows (the shape, the crop, the zooms) changed since `before` (or always without
    /// `before`); dropped when the canvas doesn't reframe.
    mutating func refreshReframe(take: AgentEditTake, since before: EditorSnapshot?) {
        let canvas = editSettings.canvas
        guard canvas.reframes, canvas.aspect != .auto else {
            editSettings.reframe = nil
            return
        }
        if let before, editSettings.reframe?.aspect == canvas.aspect,
           before.editSettings.canvas.aspect == canvas.aspect,
           before.editSettings.canvas.reframes,
           before.editSettings.sourceCrop == editSettings.sourceCrop,
           before.editSettings.cropPath == editSettings.cropPath,
           before.keyframes == keyframes {
            return
        }
        editSettings.reframe = Reframer.reframe(editSettings, keyframes: keyframes, take: take)
    }
}

extension OutputAspect {
    /// Where text can sit (normalized canvas heights, top-left origin) clear of the
    /// controls apps lay over videos of this shape: Reels, TikTok and Shorts cover the top
    /// and much of the bottom of a 9:16 video.
    var textBand: ClosedRange<CGFloat> {
        switch self {
        case .portrait: return 0.15...0.75
        case .vertical: return 0.1...0.85
        default: return 0...1
        }
    }
}

extension EditorSnapshot {
    /// This edit for a canvas of `aspect`, from the same timeline: reframed to fill it
    /// (unless `reframe` is false) and with text moved clear of the controls apps lay over
    /// that shape. For exporting or previewing other shapes.
    func variant(for aspect: OutputAspect, reframe: Bool, take: AgentEditTake) -> EditorSnapshot {
        var result = self
        guard aspect != editSettings.canvas.aspect || reframe != editSettings.canvas.reframes else { return result }
        result.editSettings.canvas.aspect = aspect
        result.editSettings.canvas.reframes = reframe
        result.refreshReframe(take: take, since: nil)
        let band = aspect.textBand
        result.editSettings.textOverlays = editSettings.textOverlays.map { overlay in
            var moved = overlay
            moved.center.y = min(max(overlay.center.y, band.lowerBound), band.upperBound)
            return moved
        }
        return result
    }
}
