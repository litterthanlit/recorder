import CoreGraphics
import Foundation

struct ZoomInterpolator {
    let keyframes: [ZoomKeyframe]

    func cropRect(at time: TimeInterval) -> NormalizedRect {
        guard !keyframes.isEmpty else { return .fullFrame }

        for keyframe in keyframes {
            if time >= keyframe.startTime && time <= keyframe.endTime {
                return rect(for: keyframe, at: time)
            }
        }

        return .fullFrame
    }

    func scale(at time: TimeInterval) -> CGFloat {
        cropRect(at: time).scaleEstimate
    }

    private func rect(for keyframe: ZoomKeyframe, at time: TimeInterval) -> NormalizedRect {
        let targetScale = keyframe.scale
        let targetCenter = keyframe.center

        let currentScale: CGFloat
        if time <= keyframe.peakTime {
            let progress = normalizedProgress(
                time: time,
                start: keyframe.startTime,
                end: keyframe.peakTime
            )
            currentScale = interpolate(from: 1, to: targetScale, progress: easeInOutCubic(progress))
        } else if time <= holdEnd(for: keyframe) {
            currentScale = targetScale
        } else {
            let holdEnd = holdEnd(for: keyframe)
            let progress = normalizedProgress(time: time, start: holdEnd, end: keyframe.endTime)
            currentScale = interpolate(from: targetScale, to: 1, progress: easeInOutCubic(progress))
        }

        let currentCenter: CGPoint
        if time <= keyframe.peakTime {
            let progress = normalizedProgress(
                time: time,
                start: keyframe.startTime,
                end: keyframe.peakTime
            )
            currentCenter = interpolate(
                from: CGPoint(x: 0.5, y: 0.5),
                to: targetCenter,
                progress: easeInOutCubic(progress)
            )
        } else if time <= holdEnd(for: keyframe) {
            currentCenter = targetCenter
        } else {
            let holdEnd = holdEnd(for: keyframe)
            let progress = normalizedProgress(time: time, start: holdEnd, end: keyframe.endTime)
            currentCenter = interpolate(
                from: targetCenter,
                to: CGPoint(x: 0.5, y: 0.5),
                progress: easeInOutCubic(progress)
            )
        }

        return makeRect(center: currentCenter, scale: currentScale)
    }

    private func holdEnd(for keyframe: ZoomKeyframe) -> TimeInterval {
        max(keyframe.peakTime, keyframe.endTime - 0.45)
    }

    private func makeRect(center: CGPoint, scale: CGFloat) -> NormalizedRect {
        let width = 1 / scale
        let height = 1 / scale
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
