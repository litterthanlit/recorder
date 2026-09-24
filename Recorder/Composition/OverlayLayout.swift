import CoreGraphics
import Foundation

/// Placement of fixed overlays in the output frame (Core Image space, bottom-left origin).
enum OverlayLayout {
    /// Where to draw a watermark of `size`: the bottom-right corner, `margin` in from the
    /// edges, unless that would overlap `avoiding` (the camera bubble); then the next free
    /// corner of bottom-left, top-right, top-left. Falls back to bottom-right.
    static func watermarkOrigin(size: CGSize, canvas: CGSize, margin: CGFloat, avoiding obstacle: CGRect?) -> CGPoint {
        let right = canvas.width - size.width - margin
        let top = canvas.height - size.height - margin
        let candidates = [
            CGPoint(x: right, y: margin),
            CGPoint(x: margin, y: margin),
            CGPoint(x: right, y: top),
            CGPoint(x: margin, y: top)
        ]
        guard let obstacle, !obstacle.isNull, !obstacle.isEmpty else { return candidates[0] }

        // Keep a margin's worth of clearance from the bubble, not just no overlap.
        let keepOut = obstacle.insetBy(dx: -margin / 2, dy: -margin / 2)
        return candidates.first { !CGRect(origin: $0, size: size).intersects(keepOut) } ?? candidates[0]
    }
}
