import CoreGraphics
import Foundation

struct ZoomInterpolator {
    let keyframes: [ZoomKeyframe]
    var springEnabled: Bool
    var springSettings: SpringSettings
    /// What the camera shows at rest (normalized, bottom-left origin): the source crop,
    /// where it is at each moment when it follows a window, or the whole recording. A
    /// zoom's scale is relative to it and its view stays in it.
    let crop: CropMotion

    init(
        keyframes: [ZoomKeyframe],
        springEnabled: Bool = false,
        springSettings: SpringSettings = .demo,
        base: CGRect = SourceCrop.full,
        path: CropPath? = nil
    ) {
        self.keyframes = keyframes.sorted { $0.startTime < $1.startTime }
        self.springEnabled = springEnabled
        self.springSettings = springSettings
        crop = CropMotion(crop: base, path: path)
    }

    /// Where the crop rests when it holds still.
    var base: CGRect {
        crop.rest
    }

    /// The crop at `time`.
    func base(at time: TimeInterval) -> CGRect {
        crop.base(at: time)
    }

    /// The camera at rest at `time`: the whole base.
    func rest(at time: TimeInterval) -> NormalizedRect {
        let shown = base(at: time)
        return NormalizedRect(x: shown.minX, y: shown.minY, width: shown.width, height: shown.height)
    }

    func cropRect(at time: TimeInterval) -> NormalizedRect {
        guard !keyframes.isEmpty else { return rest(at: time) }

        for (index, keyframe) in keyframes.enumerated() {
            if time >= keyframe.startTime && time <= keyframe.endTime {
                let previous = index > 0 ? keyframes[index - 1] : nil
                let next = index + 1 < keyframes.count ? keyframes[index + 1] : nil
                return rect(
                    for: keyframe,
                    at: time,
                    chainedFrom: previous.flatMap { ZoomKeyframeEditor.areChained($0, keyframe) ? $0 : nil },
                    chainsInto: next.map { ZoomKeyframeEditor.areChained(keyframe, $0) } ?? false
                )
            }
        }

        return rest(at: time)
    }

    /// How far the camera is zoomed in on the base (1 at rest).
    func scale(at time: TimeInterval) -> CGFloat {
        let width = cropRect(at: time).width
        guard width > 0 else { return 1 }
        return base(at: time).width / width
    }

    /// - Parameters:
    ///   - chainedFrom: the keyframe that ends where this one starts; the camera pans
    ///     from its target instead of starting at full frame.
    ///   - chainsInto: whether the next keyframe starts where this one ends; if so the
    ///     camera holds here and the next keyframe performs the move.
    private func rect(
        for keyframe: ZoomKeyframe,
        at time: TimeInterval,
        chainedFrom previous: ZoomKeyframe?,
        chainsInto: Bool
    ) -> NormalizedRect {
        let targetScale = keyframe.scale
        let targetCenter = keyframe.center
        let restScale: CGFloat = 1
        let frame = base(at: time)
        let restCenter = CGPoint(x: frame.midX, y: frame.midY)
        let startScale = previous?.scale ?? restScale
        let startCenter = previous?.center ?? restCenter
        let holdUntil = chainsInto ? keyframe.endTime : holdEnd(for: keyframe)

        let currentScale: CGFloat
        let currentCenter: CGPoint

        if time <= keyframe.peakTime {
            let (scale, center) = interpolateMotion(
                fromScale: startScale,
                toScale: targetScale,
                fromCenter: startCenter,
                toCenter: targetCenter,
                time: time,
                start: keyframe.startTime,
                end: keyframe.peakTime
            )
            currentScale = scale
            currentCenter = center
        } else if time <= holdUntil {
            currentScale = targetScale
            currentCenter = targetCenter
        } else {
            let (scale, center) = interpolateMotion(
                fromScale: targetScale,
                toScale: restScale,
                fromCenter: targetCenter,
                toCenter: restCenter,
                time: time,
                start: holdUntil,
                end: keyframe.endTime
            )
            currentScale = scale
            currentCenter = center
        }

        return makeRect(center: currentCenter, scale: currentScale, base: frame)
    }

    private func interpolateMotion(
        fromScale: CGFloat,
        toScale: CGFloat,
        fromCenter: CGPoint,
        toCenter: CGPoint,
        time: TimeInterval,
        start: TimeInterval,
        end: TimeInterval
    ) -> (CGFloat, CGPoint) {
        if springEnabled {
            let elapsed = time - start
            let duration = end - start
            return (
                SpringCamera.interpolate(
                    from: fromScale,
                    to: toScale,
                    elapsed: elapsed,
                    duration: duration,
                    settings: springSettings
                ),
                SpringCamera.interpolate(
                    from: fromCenter,
                    to: toCenter,
                    elapsed: elapsed,
                    duration: duration,
                    settings: springSettings
                )
            )
        }

        let progress = easeInOutCubic(
            normalizedProgress(time: time, start: start, end: end)
        )
        return (
            interpolate(from: fromScale, to: toScale, progress: progress),
            interpolate(from: fromCenter, to: toCenter, progress: progress)
        )
    }

    private func holdEnd(for keyframe: ZoomKeyframe) -> TimeInterval {
        max(keyframe.peakTime, keyframe.endTime - 0.45)
    }

    /// The view `scale` times closer than `base`, centred on `center` as far as the base
    /// allows.
    private func makeRect(center: CGPoint, scale: CGFloat, base: CGRect) -> NormalizedRect {
        let safeScale = max(scale, 1)
        let width = base.width / safeScale
        let height = base.height / safeScale
        let x = clamp(center.x - width / 2, min: base.minX, max: base.maxX - width)
        let y = clamp(center.y - height / 2, min: base.minY, max: base.maxY - height)
        return NormalizedRect(x: x, y: y, width: width, height: height)
    }

    private func normalizedProgress(time: TimeInterval, start: TimeInterval, end: TimeInterval) -> CGFloat {
        guard end > start else { return 1 }
        return CGFloat(clamp((time - start) / (end - start), min: 0, max: 1))
    }

    private func easeInOutCubic(_ value: CGFloat) -> CGFloat {
        if value < 0.5 {
            return 4 * value * value * value
        }
        let adjusted = -2 * value + 2
        return 1 - (adjusted * adjusted * adjusted) / 2
    }

    private func interpolate(from: CGFloat, to: CGFloat, progress: CGFloat) -> CGFloat {
        from + (to - from) * progress
    }

    private func interpolate(from: CGPoint, to: CGPoint, progress: CGFloat) -> CGPoint {
        CGPoint(
            x: interpolate(from: from.x, to: to.x, progress: progress),
            y: interpolate(from: from.y, to: to.y, progress: progress)
        )
    }

    private func clamp(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        Swift.max(min, Swift.min(max, value))
    }

    private func clamp(_ value: TimeInterval, min: TimeInterval, max: TimeInterval) -> TimeInterval {
        Swift.max(min, Swift.min(max, value))
    }
}
