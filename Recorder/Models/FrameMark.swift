import CoreGraphics

/// Trace's mark: the four corners of a viewfinder, the top-right one the REC corner (red
/// in the app icon and the brand mark, and in the menu bar while a take records).
///
/// The app icon (`scripts/make-icon.py`), the brand mark in the panel and Library, and the
/// menu bar item all draw it from these proportions, in a square with a top-left origin.
struct FrameMark: Equatable, Sendable {
    /// From each edge of the square to the centre line of the strokes, as a fraction of
    /// its side.
    let inset: CGFloat
    /// Length of each arm, from the corner to the end of its centre line.
    let arm: CGFloat
    let lineWidth: CGFloat

    enum Corner: CaseIterable {
        case topLeft, topRight, bottomRight, bottomLeft
    }

    /// The corners on the icon's body: the 824-unit body of the 1024-unit icon, strokes
    /// 66 wide whose outer edges sit 170 in from the body's edges.
    static let icon = FrameMark(inset: 203.0 / 824, arm: 124.0 / 824, lineWidth: 66.0 / 824)
    /// The corners alone, filling an 18 pt menu bar image.
    static let glyph = FrameMark(inset: 3.35 / 18, arm: 4.2 / 18, lineWidth: 2.3 / 18)

    /// The corner's centre line in a square of `side` points: one arm's end, the corner,
    /// the other arm's end.
    func polyline(_ corner: Corner, side: CGFloat) -> [CGPoint] {
        let near = inset * side
        let far = side - near
        let length = arm * side
        switch corner {
        case .topLeft:
            return [CGPoint(x: near, y: near + length), CGPoint(x: near, y: near), CGPoint(x: near + length, y: near)]
        case .topRight:
            return [CGPoint(x: far - length, y: near), CGPoint(x: far, y: near), CGPoint(x: far, y: near + length)]
        case .bottomRight:
            return [CGPoint(x: far, y: far - length), CGPoint(x: far, y: far), CGPoint(x: far - length, y: far)]
        case .bottomLeft:
            return [CGPoint(x: near + length, y: far), CGPoint(x: near, y: far), CGPoint(x: near, y: far - length)]
        }
    }
}
