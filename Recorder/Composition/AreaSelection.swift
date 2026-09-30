import CoreGraphics
import Foundation

/// Shape presets offered while drawing a recording area.
enum AreaPreset: String, CaseIterable, Identifiable, Codable {
    case free
    case widescreen
    case standard
    case square
    case portrait
    case hd720
    case hd1080

    var id: String { rawValue }

    var label: String {
        switch self {
        case .free: return "Freeform"
        case .widescreen: return "16:9"
        case .standard: return "4:3"
        case .square: return "1:1"
        case .portrait: return "9:16"
        case .hd720: return "1280 × 720"
        case .hd1080: return "1920 × 1080"
        }
    }

    /// Width over height, when the preset locks the shape.
    var aspectRatio: CGFloat? {
        switch self {
        case .free: return nil
        case .widescreen, .hd720, .hd1080: return 16.0 / 9.0
        case .standard: return 4.0 / 3.0
        case .square: return 1
        case .portrait: return 9.0 / 16.0
        }
    }

    /// Exact recorded size in pixels, for the fixed-size presets.
    var pixelSize: CGSize? {
        switch self {
        case .hd720: return CGSize(width: 1280, height: 720)
        case .hd1080: return CGSize(width: 1920, height: 1080)
        case .free, .widescreen, .standard, .square, .portrait: return nil
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AreaPreset(rawValue: raw) ?? .free
    }
}

/// Where the recording area is: a display and a rect in that display's points with a
/// top-left origin (the space `SCStreamConfiguration.sourceRect` and the selection overlay
/// use).
struct CaptureArea: Codable, Equatable {
    var displayID: UInt32
    var rect: CGRect
}

/// Drawing, moving and resizing the recording area. All rects are in one top-left-origin
/// space (a display's points); `bounds` is the display.
enum AreaSelection {
    enum Handle: CaseIterable, Equatable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var movesLeftEdge: Bool { self == .topLeft || self == .left || self == .bottomLeft }
        var movesRightEdge: Bool { self == .topRight || self == .right || self == .bottomRight }
        var movesTopEdge: Bool { self == .topLeft || self == .top || self == .topRight }
        var movesBottomEdge: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
        var isCorner: Bool { self == .topLeft || self == .topRight || self == .bottomLeft || self == .bottomRight }

        func point(in rect: CGRect) -> CGPoint {
            let x: CGFloat = movesLeftEdge ? rect.minX : (movesRightEdge ? rect.maxX : rect.midX)
            let y: CGFloat = movesTopEdge ? rect.minY : (movesBottomEdge ? rect.maxY : rect.midY)
            return CGPoint(x: x, y: y)
        }
    }

    enum Hit: Equatable {
        case handle(Handle)
        case body
    }

    static let minimumSize = CGSize(width: 64, height: 64)

    /// What's under `point`: a resize handle (within `handleRadius` of it), the area's
    /// body, or nothing. Corners win over edges, and handles over the body.
    static func hitTest(_ point: CGPoint, rect: CGRect, handleRadius: CGFloat = 8) -> Hit? {
        let ordered: [Handle] = [.topLeft, .topRight, .bottomRight, .bottomLeft, .top, .right, .bottom, .left]
        for handle in ordered {
            let center = handle.point(in: rect)
            if abs(point.x - center.x) <= handleRadius, abs(point.y - center.y) <= handleRadius {
                return .handle(handle)
            }
        }
        // Grab edges along their whole length, not just at the midpoint handle.
        let outer = rect.insetBy(dx: -handleRadius / 2, dy: -handleRadius / 2)
        let inner = rect.insetBy(dx: handleRadius / 2, dy: handleRadius / 2)
        if outer.contains(point), !inner.contains(point) {
            if abs(point.x - rect.minX) <= handleRadius / 2 { return .handle(.left) }
            if abs(point.x - rect.maxX) <= handleRadius / 2 { return .handle(.right) }
            if abs(point.y - rect.minY) <= handleRadius / 2 { return .handle(.top) }
            if abs(point.y - rect.maxY) <= handleRadius / 2 { return .handle(.bottom) }
        }
        return rect.contains(point) ? .body : nil
    }

    /// A new area dragged out from `start` to `current`, locked to `aspect` if given
    /// (anchored at `start`), and kept inside `bounds`.
    static func rect(
        from start: CGPoint,
        to current: CGPoint,
        aspect: CGFloat?,
        bounds: CGRect
    ) -> CGRect {
        let anchor = clamp(start, to: bounds)
        let end = clamp(current, to: bounds)
        guard let aspect, aspect > 0 else {
            return CGRect(
                x: min(anchor.x, end.x),
                y: min(anchor.y, end.y),
                width: abs(end.x - anchor.x),
                height: abs(end.y - anchor.y)
            )
        }
        let goesRight = end.x >= anchor.x
        let goesDown = end.y >= anchor.y
        let availableWidth = goesRight ? bounds.maxX - anchor.x : anchor.x - bounds.minX
        let availableHeight = goesDown ? bounds.maxY - anchor.y : anchor.y - bounds.minY
        var width = max(abs(end.x - anchor.x), abs(end.y - anchor.y) * aspect)
        width = min(width, availableWidth, availableHeight * aspect)
        let height = width / aspect
        return CGRect(
            x: goesRight ? anchor.x : anchor.x - width,
            y: goesDown ? anchor.y : anchor.y - height,
            width: width,
            height: height
        )
    }

    /// Drags `handle` to `point`. The opposite edge or corner stays put; with an aspect
    /// lock, edge handles grow the other dimension around the centre. The result stays
    /// inside `bounds` and at least `minimumSize`.
    static func resize(
        _ rect: CGRect,
        handle: Handle,
        to point: CGPoint,
        aspect: CGFloat?,
        bounds: CGRect,
        minimumSize: CGSize = AreaSelection.minimumSize
    ) -> CGRect {
        let point = clamp(point, to: bounds)
        guard let aspect, aspect > 0 else {
            var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
            if handle.movesLeftEdge { minX = min(point.x, maxX - minimumSize.width) }
            if handle.movesRightEdge { maxX = max(point.x, minX + minimumSize.width) }
            if handle.movesTopEdge { minY = min(point.y, maxY - minimumSize.height) }
            if handle.movesBottomEdge { maxY = max(point.y, minY + minimumSize.height) }
            return clampRect(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), to: bounds)
        }

        let minimumWidth = max(minimumSize.width, minimumSize.height * aspect)
        if handle.isCorner {
            let anchor = CGPoint(
                x: handle.movesLeftEdge ? rect.maxX : rect.minX,
                y: handle.movesTopEdge ? rect.maxY : rect.minY
            )
            let availableWidth = handle.movesLeftEdge ? anchor.x - bounds.minX : bounds.maxX - anchor.x
            let availableHeight = handle.movesTopEdge ? anchor.y - bounds.minY : bounds.maxY - anchor.y
            var width = max(abs(point.x - anchor.x), abs(point.y - anchor.y) * aspect)
            width = min(max(width, minimumWidth), availableWidth, availableHeight * aspect)
            let height = width / aspect
            return CGRect(
                x: handle.movesLeftEdge ? anchor.x - width : anchor.x,
                y: handle.movesTopEdge ? anchor.y - height : anchor.y,
                width: width,
                height: height
            )
        }

        // Edge handle: that edge follows the pointer, the other dimension grows evenly.
        var width: CGFloat
        if handle == .left || handle == .right {
            width = handle == .left ? rect.maxX - point.x : point.x - rect.minX
        } else {
            let height = handle == .top ? rect.maxY - point.y : point.y - rect.minY
            width = height * aspect
        }
        let horizontalRoom = handle == .left ? rect.maxX - bounds.minX
            : handle == .right ? bounds.maxX - rect.minX : bounds.width
        let verticalRoom = handle == .top ? rect.maxY - bounds.minY
            : handle == .bottom ? bounds.maxY - rect.minY : bounds.height
        width = min(max(width, minimumWidth), horizontalRoom, verticalRoom * aspect)
        let height = width / aspect

        var result: CGRect
        switch handle {
        case .left:
            result = CGRect(x: rect.maxX - width, y: rect.midY - height / 2, width: width, height: height)
        case .right:
            result = CGRect(x: rect.minX, y: rect.midY - height / 2, width: width, height: height)
        case .top:
            result = CGRect(x: rect.midX - width / 2, y: rect.maxY - height, width: width, height: height)
        default:
            result = CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: height)
        }
        return clampRect(result, to: bounds)
    }

    /// Moves the area by `delta`, stopping at the edges of `bounds`.
    static func move(_ rect: CGRect, by delta: CGSize, within bounds: CGRect) -> CGRect {
        clampRect(rect.offsetBy(dx: delta.width, dy: delta.height), to: bounds)
    }

    /// Reshapes the area for a preset around its centre: aspect presets keep the width
    /// (or shrink to fit), fixed sizes become exactly that many pixels at `scale`.
    static func apply(_ preset: AreaPreset, to rect: CGRect, scale: CGFloat, bounds: CGRect) -> CGRect {
        var size: CGSize
        if let pixels = preset.pixelSize {
            let pointsPerPixel = 1 / (scale > 0 ? scale : 1)
            size = CGSize(width: pixels.width * pointsPerPixel, height: pixels.height * pointsPerPixel)
        } else if let aspect = preset.aspectRatio {
            size = CGSize(width: rect.width, height: rect.width / aspect)
            if size.height > bounds.height {
                size = CGSize(width: bounds.height * aspect, height: bounds.height)
            }
        } else {
            return clampRect(rect, to: bounds)
        }
        if size.width > bounds.width || size.height > bounds.height {
            let fit = min(bounds.width / size.width, bounds.height / size.height)
            size = CGSize(width: size.width * fit, height: size.height * fit)
        }
        let centered = CGRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        return clampRect(centered, to: bounds)
    }

    /// Shifts `rect` inside `bounds`, shrinking it only if it's bigger.
    static func clampRect(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        let width = min(rect.width, bounds.width)
        let height = min(rect.height, bounds.height)
        let x = min(max(rect.minX, bounds.minX), bounds.maxX - width)
        let y = min(max(rect.minY, bounds.minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func clamp(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }
}
