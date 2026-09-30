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

    /// A box of `size` centred on `center` (normalized, top-left origin, as text overlays
    /// store it) on `canvas`, in Core Image space, moved back inside the canvas (`margin`
    /// from the edges) if it would stick out.
    static func centeredFrame(size: CGSize, normalizedCenter center: CGPoint, canvas: CGSize, margin: CGFloat) -> CGRect {
        let x = center.x * canvas.width - size.width / 2
        let y = (1 - center.y) * canvas.height - size.height / 2
        let maxX = max(margin, canvas.width - size.width - margin)
        let maxY = max(margin, canvas.height - size.height - margin)
        return CGRect(
            x: min(max(x, margin), maxX),
            y: min(max(y, margin), maxY),
            width: size.width,
            height: size.height
        )
    }

    /// Where the keystroke pill goes: centred on the recording, `margin` in from its
    /// bottom or top edge.
    static func keystrokeOrigin(
        size: CGSize,
        contentFrame: CGRect,
        placement: KeystrokeOverlayStyle.Placement,
        margin: CGFloat
    ) -> CGPoint {
        let x = contentFrame.midX - size.width / 2
        let y = placement == .bottom
            ? contentFrame.minY + margin
            : contentFrame.maxY - margin - size.height
        return CGPoint(x: x, y: y)
    }
}

enum CameraBubblePosition: String, Codable, CaseIterable, Identifiable {
    case bottomRight
    case bottomLeft
    case topRight
    case topLeft

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bottomRight: return "Bottom Right"
        case .bottomLeft: return "Bottom Left"
        case .topRight: return "Top Right"
        case .topLeft: return "Top Left"
        }
    }

    /// The corner of `container` closest to `point` (both bottom-left origin), for
    /// snapping a dragged bubble.
    static func nearest(to point: CGPoint, in container: CGRect) -> CameraBubblePosition {
        let isRight = point.x >= container.midX
        let isTop = point.y >= container.midY
        switch (isRight, isTop) {
        case (true, false): return .bottomRight
        case (false, false): return .bottomLeft
        case (true, true): return .topRight
        case (false, true): return .topLeft
        }
    }
}

enum CameraBubbleSize: String, Codable, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var label: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    /// Diameter of the live bubble on screen while recording, in points.
    var livePoints: CGFloat {
        switch self {
        case .small: return 120
        case .medium: return 168
        case .large: return 240
        }
    }

    /// Bubble diameter as a fraction of the shorter frame edge.
    var diameterFraction: CGFloat {
        switch self {
        case .small: return 0.13
        case .medium: return 0.18
        case .large: return 0.25
        }
    }
}

enum CameraBubbleLayout {
    static let paddingFraction: CGFloat = 0.035

    /// The bubble's square in a frame of `bounds` (bottom-left origin).
    static func frame(in bounds: CGSize, position: CameraBubblePosition, size: CameraBubbleSize = .medium) -> CGRect {
        frame(in: bounds, position: position, diameterFraction: size.diameterFraction)
    }

    /// The bubble's square in a frame of `bounds` (bottom-left origin), `diameterFraction`
    /// of its shorter side across (at most what fits inside the padding).
    static func frame(in bounds: CGSize, position: CameraBubblePosition, diameterFraction: CGFloat) -> CGRect {
        let shorter = min(bounds.width, bounds.height)
        let padding = shorter * paddingFraction
        let fraction = diameterFraction.isFinite ? max(0, diameterFraction) : 0
        let diameter = min(shorter * fraction, max(0, shorter - padding * 2))

        let x: CGFloat
        let y: CGFloat
        switch position {
        case .bottomRight:
            x = bounds.width - diameter - padding
            y = padding
        case .bottomLeft:
            x = padding
            y = padding
        case .topRight:
            x = bounds.width - diameter - padding
            y = bounds.height - diameter - padding
        case .topLeft:
            x = padding
            y = bounds.height - diameter - padding
        }
        return CGRect(x: x, y: y, width: diameter, height: diameter)
    }
}
