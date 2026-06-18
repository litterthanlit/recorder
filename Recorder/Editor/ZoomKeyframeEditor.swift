import CoreGraphics
import Foundation

enum ZoomKeyframeEditor {
    static let minimumSpan: TimeInterval = 0.25
    static let defaultEaseIn: TimeInterval = 0.35
    static let defaultHold: TimeInterval = 1.2
    static let defaultEaseOut: TimeInterval = 0.45
    static let minimumManualScale: CGFloat = 1.2
    static let maximumManualScale: CGFloat = 3.0

    static func resolveOverlaps(_ keyframes: inout [ZoomKeyframe]) {
        guard keyframes.count > 1 else { return }

        keyframes.sort { $0.startTime < $1.startTime }

        for index in 1..<keyframes.count {
            let previous = keyframes[index - 1]
            var current = keyframes[index]

            if current.startTime < previous.endTime {
                let shiftedStart = previous.endTime
                let duration = current.endTime - current.startTime
                let peakOffset = current.peakTime - current.startTime

                current.startTime = shiftedStart
                current.peakTime = shiftedStart + peakOffset
                current.endTime = shiftedStart + duration
                keyframes[index] = current
            }
        }
    }

    static func clampKeyframe(_ keyframe: ZoomKeyframe, duration: TimeInterval) -> ZoomKeyframe {
        var updated = keyframe
        let span = max(minimumSpan, updated.endTime - updated.startTime)

        updated.startTime = max(0, min(updated.startTime, duration - span))
        updated.endTime = min(duration, updated.startTime + span)
        updated.peakTime = max(updated.startTime, min(updated.peakTime, updated.endTime))

        if updated.endTime - updated.startTime < minimumSpan {
            updated.endTime = min(duration, updated.startTime + minimumSpan)
        }

        return updated
    }

    static func moveKeyframe(_ keyframe: ZoomKeyframe, by delta: TimeInterval, duration: TimeInterval) -> ZoomKeyframe {
        var updated = keyframe
        let span = updated.endTime - updated.startTime
        let newStart = updated.startTime + delta
        updated.startTime = max(0, min(newStart, duration - span))
        updated.endTime = updated.startTime + span
        updated.peakTime = updated.startTime + (keyframe.peakTime - keyframe.startTime)
        updated.peakTime = max(updated.startTime, min(updated.peakTime, updated.endTime))
        return updated
    }

    static func resizeKeyframeStart(_ keyframe: ZoomKeyframe, to newStart: TimeInterval, duration: TimeInterval) -> ZoomKeyframe {
        var updated = keyframe
        updated.startTime = max(0, min(newStart, updated.endTime - minimumSpan))
        updated.peakTime = max(updated.startTime, min(updated.peakTime, updated.endTime))
        return clampKeyframe(updated, duration: duration)
    }

    static func resizeKeyframeEnd(_ keyframe: ZoomKeyframe, to newEnd: TimeInterval, duration: TimeInterval) -> ZoomKeyframe {
        var updated = keyframe
        updated.endTime = min(duration, max(newEnd, updated.startTime + minimumSpan))
        updated.peakTime = max(updated.startTime, min(updated.peakTime, updated.endTime))
        return clampKeyframe(updated, duration: duration)
    }

    static func makeManualKeyframe(
        at playhead: TimeInterval,
        normalizedRect: CGRect,
        duration: TimeInterval,
        settings: AutoZoomSettings = AutoZoomSettings()
    ) -> ZoomKeyframe {
        let clampedRect = clampNormalizedRect(normalizedRect)
        let center = CGPoint(
            x: clampedRect.midX,
            y: clampedRect.midY
        )
        let scale = min(
            maximumManualScale,
            max(minimumManualScale, 1 / max(clampedRect.width, clampedRect.height))
        )

        let peakTime = max(0, min(playhead, duration))
        let startTime = max(0, peakTime - settings.easeInDuration)
        let endTime = min(duration, peakTime + settings.holdDuration + settings.easeOutDuration)

        return ZoomKeyframe(
            startTime: startTime,
            peakTime: peakTime,
            endTime: endTime,
            center: center,
            scale: scale,
            source: .manual
        )
    }

    static func clampNormalizedRect(_ rect: CGRect) -> CGRect {
        let width = max(0.08, min(1, rect.width))
        let height = max(0.08, min(1, rect.height))
        var x = rect.midX - width / 2
        var y = rect.midY - height / 2
        x = max(0, min(x, 1 - width))
        y = max(0, min(y, 1 - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
