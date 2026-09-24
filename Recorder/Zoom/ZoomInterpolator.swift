import CoreGraphics
import Foundation

struct ZoomInterpolator {
    let keyframes: [ZoomKeyframe]
    var springEnabled: Bool
    var springSettings: SpringSettings

    init(
        keyframes: [ZoomKeyframe],
        springEnabled: Bool = false,
        springSettings: SpringSettings = .demo
    ) {
        self.keyframes = keyframes.sorted { $0.startTime < $1.startTime }
        self.springEnabled = springEnabled
        self.springSettings = springSettings
    }

    func cropRect(at time: TimeInterval) -> NormalizedRect {
        guard !keyframes.isEmpty else { return .fullFrame }

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

        return .fullFrame
    }

    func scale(at time: TimeInterval) -> CGFloat {
        cropRect(at: time).scaleEstimate
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
        let restCenter = CGPoint(x: 0.5, y: 0.5)
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

        return makeRect(center: currentCenter, scale: currentScale)
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

    private func makeRect(center: CGPoint, scale: CGFloat) -> NormalizedRect {
        let safeScale = max(scale, 1)
        let width = 1 / safeScale
        let height = 1 / safeScale
        let x = clamp(center.x - width / 2, min: 0, max: 1 - width)
        let y = clamp(center.y - height / 2, min: 0, max: 1 - height)
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

private extension NormalizedRect {
    var scaleEstimate: CGFloat {
        guard width > 0 else { return 1 }
        return 1 / width
    }
}
