import CoreGraphics
import Foundation

/// Maps between screen points and the recorded movie's pixels.
enum CaptureGeometry {
    /// Pixel size of a capture of `points` at `scale` pixels per point, rounded to even
    /// numbers: H.264/HEVC encoders use 4:2:0 chroma and reject (or pad) odd dimensions,
    /// which a window with an odd point size at 1x (or a fractional scale) would produce.
    static func pixelSize(points: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        (evenPixels(points.width * scale), evenPixels(points.height * scale))
    }

    /// Where a global event location lands in the capture, in pixels with a bottom-left
    /// origin (Core Image space).
    ///
    /// - Parameters:
    ///   - global: `CGEvent.location`, in global display points with a top-left origin.
    ///   - origin: the captured area's top-left corner in the same global space (a
    ///     display's `CGDisplayBounds` origin, or an `SCWindow.frame` origin). Not an
    ///     `NSScreen.frame` origin, which is bottom-left based and only matches for the
    ///     main display.
    ///   - scale: pixels per point.
    ///   - pixelHeight: the capture's height in pixels.
    static func capturePoint(global: CGPoint, origin: CGPoint, scale: CGFloat, pixelHeight: CGFloat) -> CGPoint {
        let x = (global.x - origin.x) * scale
        let yFromTop = (global.y - origin.y) * scale
        return CGPoint(x: x, y: pixelHeight - yFromTop)
    }

    private static func evenPixels(_ value: CGFloat) -> Int {
        guard value.isFinite, value > 0 else { return 2 }
        let rounded = Int(value.rounded())
        return max(2, rounded - rounded % 2)
    }
}
