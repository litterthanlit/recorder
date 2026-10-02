import CoreGraphics
import Foundation

enum ZoomKeyframeEditor {
    static let minimumSpan: TimeInterval = 0.25
    static let defaultEaseIn: TimeInterval = 0.35
    static let defaultHold: TimeInterval = 1.2
    static let defaultEaseOut: TimeInterval = 0.45
    static let minimumManualScale: CGFloat = 1.2
    static let maximumManualScale: CGFloat = 3.0

    /// Makes keyframes non-overlapping without moving them in time.
    ///
    /// When two zooms overlap, the earlier one is cut short at a shared boundary and the
    /// later one starts there, so each zoom still peaks when its click happened. The
    /// interpolator treats such back-to-back keyframes as a pan from one target to the
    /// next instead of zooming out to full frame in between.
    static func resolveOverlaps(_ keyframes: inout [ZoomKeyframe]) {
        guard keyframes.count > 1 else { return }

        keyframes.sort { $0.peakTime < $1.peakTime }

        for index in 1..<keyframes.count {
            var previous = keyframes[index - 1]
            var current = keyframes[index]

            guard current.startTime < previous.endTime else { continue }

            let boundary = max(current.startTime, previous.peakTime)
            previous.endTime = boundary
            current.startTime = boundary
            current.peakTime = max(current.peakTime, boundary)
            current.endTime = max(current.endTime, current.peakTime)

            keyframes[index - 1] = previous
            keyframes[index] = current
        }
    }

    /// `keyframes` with the auto zooms replaced by fresh ones from `clicks` for `preset`;
    /// manual zooms stay. Sorted, without overlaps.
    static func replacingAutoZooms(
        in keyframes: [ZoomKeyframe],
        clicks: [ClickEvent],
        preset: ZoomPreset,
        frameSize: CGSize
    ) -> [ZoomKeyframe] {
        let generator = AutoZoomGenerator(
            settings: preset.settings,
            frameWidth: frameSize.width,
            frameHeight: frameSize.height
        )
        let manual = keyframes.filter { $0.source == .manual }
        var result = (generator.generate(from: clicks) + manual).sorted { $0.startTime < $1.startTime }
        resolveOverlaps(&result)
        return result
    }

    /// True when `next` begins exactly where `previous` ends, i.e. the camera should
    /// travel directly between their targets.
    static func areChained(_ previous: ZoomKeyframe, _ next: ZoomKeyframe) -> Bool {
        abs(next.startTime - previous.endTime) < chainTolerance
    }

    static let chainTolerance: TimeInterval = 0.001

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

    /// - Parameter base: what the video shows at rest (the source crop); the scale is
    ///   relative to it.
    static func makeManualKeyframe(
        at playhead: TimeInterval,
        normalizedRect: CGRect,
        duration: TimeInterval,
        settings: AutoZoomSettings = AutoZoomSettings(),
        base: CGRect = SourceCrop.full
    ) -> ZoomKeyframe {
        let clampedRect = clampNormalizedRect(normalizedRect)
        let center = CGPoint(
            x: clampedRect.midX,
            y: clampedRect.midY
        )
        let scale = min(
            maximumManualScale,
            max(minimumManualScale, fittingScale(for: clampedRect, base: base))
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

    /// Where the renderer draws the video inside a canvas: aspect-fit within the padded
    /// area and centered. Mirrors `CompositionRenderer.fitContent`.
    static func fittedContentFrame(contentAspect: CGFloat, in canvas: CGSize, padding: CGFloat) -> CGRect {
        let available = CGSize(width: canvas.width - padding * 2, height: canvas.height - padding * 2)
        guard contentAspect > 0, available.width > 0, available.height > 0 else { return .zero }

        let scale = min(available.width / contentAspect, available.height)
        let size = CGSize(width: contentAspect * scale, height: scale)
        return CGRect(
            x: padding + (available.width - size.width) / 2,
            y: padding + (available.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Converts a selection drawn over the preview into a normalized source rect.
    ///
    /// - Parameters:
    ///   - selection: the dragged rectangle in view coordinates (top-left origin, y down).
    ///   - contentFrame: where the video is drawn in the same view coordinates.
    ///   - visibleCrop: the part of the source currently shown (the preview may already be zoomed).
    /// - Returns: a rect in normalized source space with a bottom-left origin (y up), the
    ///   same space as click locations and keyframe centers, or `nil` if the selection
    ///   misses the video.
    static func sourceRect(
        forSelection selection: CGRect,
        contentFrame: CGRect,
        visibleCrop: NormalizedRect
    ) -> CGRect? {
        guard contentFrame.width > 0, contentFrame.height > 0 else { return nil }
        let clipped = selection.intersection(contentFrame)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }

        let localMinX = (clipped.minX - contentFrame.minX) / contentFrame.width
        let localMaxX = (clipped.maxX - contentFrame.minX) / contentFrame.width
        // View y grows downward; source y grows upward.
        let localMinY = (contentFrame.maxY - clipped.maxY) / contentFrame.height
        let localMaxY = (contentFrame.maxY - clipped.minY) / contentFrame.height

        return CGRect(
            x: visibleCrop.x + localMinX * visibleCrop.width,
            y: visibleCrop.y + localMinY * visibleCrop.height,
            width: (localMaxX - localMinX) * visibleCrop.width,
            height: (localMaxY - localMinY) * visibleCrop.height
        )
    }

    /// Inverse of `sourceRect(forSelection:contentFrame:visibleCrop:)`: where a normalized
    /// source rect (bottom-left origin) appears in the view (top-left origin), given what
    /// part of the source is on screen. Parts outside the visible crop fall outside
    /// `contentFrame`.
    static func viewRect(forSource rect: CGRect, contentFrame: CGRect, visibleCrop: NormalizedRect) -> CGRect {
        guard visibleCrop.width > 0, visibleCrop.height > 0 else { return .zero }
        let localMinX = (rect.minX - visibleCrop.x) / visibleCrop.width
        let localMaxX = (rect.maxX - visibleCrop.x) / visibleCrop.width
        let localMinY = (rect.minY - visibleCrop.y) / visibleCrop.height
        let localMaxY = (rect.maxY - visibleCrop.y) / visibleCrop.height
        return CGRect(
            x: contentFrame.minX + localMinX * contentFrame.width,
            y: contentFrame.maxY - localMaxY * contentFrame.height,
            width: (localMaxX - localMinX) * contentFrame.width,
            height: (localMaxY - localMinY) * contentFrame.height
        )
    }

    /// Where a box drawn over the view (top-left origin) lies in normalized source space
    /// (bottom-left origin), without clipping it to the video, for dragging boxes that
    /// may stick out. The inverse of `viewRect(forSource:contentFrame:visibleCrop:)`.
    static func unclippedSourceRect(forView rect: CGRect, contentFrame: CGRect, visibleCrop: NormalizedRect) -> CGRect {
        guard contentFrame.width > 0, contentFrame.height > 0 else { return .zero }
        return CGRect(
            x: visibleCrop.x + (rect.minX - contentFrame.minX) / contentFrame.width * visibleCrop.width,
            y: visibleCrop.y + (contentFrame.maxY - rect.maxY) / contentFrame.height * visibleCrop.height,
            width: rect.width / contentFrame.width * visibleCrop.width,
            height: rect.height / contentFrame.height * visibleCrop.height
        )
    }

    /// Scales a zoom can be given by editing its focus.
    static let focusScaleRange: ClosedRange<CGFloat> = 1.1...4

    /// The part of the recording a zoom shows at its peak (normalized, bottom-left
    /// origin), matching the interpolator's crop. `base` is what the video shows at rest
    /// (the source crop).
    static func focusRect(for keyframe: ZoomKeyframe, base: CGRect = SourceCrop.full) -> CGRect {
        let scale = max(keyframe.scale, 1)
        let width = base.width / scale
        let height = base.height / scale
        return CGRect(
            x: min(max(keyframe.centerX - width / 2, base.minX), base.maxX - width),
            y: min(max(keyframe.centerY - height / 2, base.minY), base.maxY - height),
            width: width,
            height: height
        )
    }

    /// The zoom pointed at `center` (normalized), kept so its focus stays inside `base`.
    static func keyframe(_ keyframe: ZoomKeyframe, movingFocusTo center: CGPoint, base: CGRect = SourceCrop.full) -> ZoomKeyframe {
        var updated = keyframe
        let scale = max(keyframe.scale, 1)
        let halfWidth = base.width / scale / 2
        let halfHeight = base.height / scale / 2
        updated.center = CGPoint(
            x: min(max(center.x, base.minX + halfWidth), base.maxX - halfWidth),
            y: min(max(center.y, base.minY + halfHeight), base.maxY - halfHeight)
        )
        return updated
    }

    /// The zoom showing `rect` (normalized): its centre, and the closest scale that still
    /// shows all of it, within `focusScaleRange`.
    static func keyframe(_ keyframe: ZoomKeyframe, focusingOn rect: CGRect, base: CGRect = SourceCrop.full) -> ZoomKeyframe {
        var updated = keyframe
        let scale = fittingScale(for: rect, base: base)
        updated.scale = min(max(scale, focusScaleRange.lowerBound), focusScaleRange.upperBound)
        return Self.keyframe(updated, movingFocusTo: CGPoint(x: rect.midX, y: rect.midY), base: base)
    }

    /// How many times closer than `base` a view can be and still show all of `rect`
    /// (the upper end of `focusScaleRange` for an empty rect).
    static func fittingScale(for rect: CGRect, base: CGRect) -> CGFloat {
        let side = max(rect.width / max(base.width, 1e-6), rect.height / max(base.height, 1e-6))
        return side > 0 ? 1 / side : focusScaleRange.upperBound
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
