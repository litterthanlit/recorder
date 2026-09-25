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
        let shorter = min(bounds.width, bounds.height)
        let diameter = shorter * size.diameterFraction
        let padding = shorter * paddingFraction

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
