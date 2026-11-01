import CoreGraphics
import Testing
@testable import RecorderCore

@Suite("Frame mark")
struct FrameMarkTests {
    @Test(arguments: [FrameMark.icon, FrameMark.glyph])
    func cornersMirrorEachOther(mark: FrameMark) {
        let side: CGFloat = 100
        let topLeft = mark.polyline(.topLeft, side: side)
        let mirrors: [(FrameMark.Corner, (CGPoint) -> CGPoint)] = [
            (.topRight, { CGPoint(x: side - $0.x, y: $0.y) }),
            (.bottomLeft, { CGPoint(x: $0.x, y: side - $0.y) }),
            (.bottomRight, { CGPoint(x: side - $0.x, y: side - $0.y) })
        ]
        for (corner, mirror) in mirrors {
            let points = mark.polyline(corner, side: side)
            // Same three points, in either direction along the corner.
            let expected = topLeft.map(mirror)
            let matches = { (a: [CGPoint], b: [CGPoint]) in
                zip(a, b).allSatisfy { isClose($0.x, $1.x, tolerance: 1e-9) && isClose($0.y, $1.y, tolerance: 1e-9) }
            }
            #expect(matches(points, expected) || matches(points, expected.reversed()), "\(corner)")
            // The corner point is in the middle.
            #expect(isClose(points[1].x, expected[1].x, tolerance: 1e-9) && isClose(points[1].y, expected[1].y, tolerance: 1e-9))
        }
    }

    @Test(arguments: [FrameMark.icon, FrameMark.glyph])
    func strokesStayInsideAndCornersStaySeparate(mark: FrameMark) {
        let side: CGFloat = 18
        let halfWidth = mark.lineWidth * side / 2
        for corner in FrameMark.Corner.allCases {
            for point in mark.polyline(corner, side: side) {
                #expect(point.x - halfWidth > 0 && point.x + halfWidth < side)
                #expect(point.y - halfWidth > 0 && point.y + halfWidth < side)
            }
        }
        // Round caps of facing arms leave a gap, so the four corners read as four.
        let topLeftEnd = mark.polyline(.topLeft, side: side)[2]
        let topRightEnd = mark.polyline(.topRight, side: side)[0]
        #expect(topRightEnd.x - topLeftEnd.x > 2 * halfWidth)
    }

    @Test func iconMatchesTheIconGenerator() {
        // scripts/make-icon.py draws the icon at 1024 px with its body from 100 to 924.
        let points = FrameMark.icon.polyline(.topRight, side: 824).map { CGPoint(x: $0.x + 100, y: $0.y + 100) }
        #expect(isClose(points[1].x, 721, tolerance: 1e-9))
        #expect(isClose(points[1].y, 303, tolerance: 1e-9))
        #expect(isClose(FrameMark.icon.lineWidth * 824, 66, tolerance: 1e-9))
        #expect(isClose(FrameMark.icon.arm * 824, 124, tolerance: 1e-9))
    }
}
