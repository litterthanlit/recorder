import CoreGraphics
import Foundation
import Testing
@testable import RecorderCore

@Suite("Area capture geometry")
struct AreaCaptureGeometryTests {
    private let display = CGSize(width: 1512, height: 982)

    @Test func keepsAnAreaThatIsAlreadyOnWholePixels() throws {
        let rect = try #require(CaptureGeometry.areaSourceRect(
            CGRect(x: 100, y: 50, width: 800, height: 450), displaySize: display, scale: 2
        ))
        #expect(rect == CGRect(x: 100, y: 50, width: 800, height: 450))
        let pixels = CaptureGeometry.pixelSize(points: rect.size, scale: 2)
        #expect(pixels.width == 1600 && pixels.height == 900)
    }

    @Test func clipsToTheDisplay() throws {
        let rect = try #require(CaptureGeometry.areaSourceRect(
            CGRect(x: -40, y: 900, width: 400, height: 400), displaySize: display, scale: 2
        ))
        #expect(rect.minX == 0)
        #expect(rect.minY == 900)
        #expect(rect.maxY <= display.height)
        #expect(isClose(rect.width, 360))
    }

    @Test func snapsToEvenPixelsAtFractionalScale() throws {
        let scale: CGFloat = 1.5
        let rect = try #require(CaptureGeometry.areaSourceRect(
            CGRect(x: 10.2, y: 20.7, width: 333.3, height: 201.1), displaySize: display, scale: scale
        ))
        let widthPixels = rect.width * scale
        let heightPixels = rect.height * scale
        #expect(isClose(widthPixels, widthPixels.rounded(), tolerance: 1e-6))
        #expect(Int(widthPixels.rounded()) % 2 == 0)
        #expect(Int(heightPixels.rounded()) % 2 == 0)
        // Shrunk inward, never grown past what was drawn.
        #expect(rect.minX >= 10.2 && rect.maxX <= 10.2 + 333.3)
        let pixels = CaptureGeometry.pixelSize(points: rect.size, scale: scale)
        #expect(pixels.width == Int(widthPixels.rounded()))
        #expect(pixels.height == Int(heightPixels.rounded()))
    }

    @Test func rejectsTinyOrOffscreenAreas() {
        #expect(CaptureGeometry.areaSourceRect(
            CGRect(x: 10, y: 10, width: 20, height: 400), displaySize: display, scale: 2
        ) == nil)
        #expect(CaptureGeometry.areaSourceRect(
            CGRect(x: 2000, y: 10, width: 200, height: 200), displaySize: display, scale: 2
        ) == nil)
        #expect(CaptureGeometry.areaSourceRect(
            CGRect(x: CGFloat.nan, y: 10, width: 200, height: 200), displaySize: display, scale: 2
        ) == nil)
    }

    @Test func mapsClicksInAnAreaOnADisplayLeftOfMain() {
        // Display at global x = -1920; the area starts 100 pt in and 200 pt down.
        let origin = CGPoint(x: -1920 + 100, y: 200)
        let point = CaptureGeometry.capturePoint(
            global: CGPoint(x: -1920 + 150, y: 260), origin: origin, scale: 2, pixelHeight: 400
        )
        #expect(isClose(point.x, 100))
        #expect(isClose(point.y, 400 - 120))
    }

    @Test func picksTheWindowUnderThePointerSkippingOwnWindows() {
        let windows = [
            WindowSnapshot(windowID: 1, layer: 3, bounds: CGRect(x: 0, y: 0, width: 500, height: 500), ownerPID: 10),
            WindowSnapshot(windowID: 2, layer: 0, bounds: CGRect(x: 0, y: 0, width: 300, height: 300), ownerPID: 99),
            WindowSnapshot(windowID: 3, layer: 0, bounds: CGRect(x: 0, y: 0, width: 400, height: 400), ownerPID: 10)
        ]
        let hit = WindowHitTest.frontmostWindow(at: CGPoint(x: 50, y: 50), frontToBack: windows, excludingOwner: 99)
        #expect(hit?.windowID == 3)
        #expect(WindowHitTest.frontmostWindow(at: CGPoint(x: 450, y: 450), frontToBack: windows, excludingOwner: 99) == nil)
    }
}

@Suite("Area selection")
struct AreaSelectionTests {
    private let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let rect = CGRect(x: 100, y: 100, width: 400, height: 300)

    @Test func hitTestFindsHandlesEdgesAndBody() {
        #expect(AreaSelection.hitTest(CGPoint(x: 101, y: 99), rect: rect) == .handle(.topLeft))
        #expect(AreaSelection.hitTest(CGPoint(x: 500, y: 400), rect: rect) == .handle(.bottomRight))
        #expect(AreaSelection.hitTest(CGPoint(x: 300, y: 100), rect: rect) == .handle(.top))
        #expect(AreaSelection.hitTest(CGPoint(x: 499, y: 180), rect: rect) == .handle(.right))
        #expect(AreaSelection.hitTest(CGPoint(x: 300, y: 250), rect: rect) == .body)
        #expect(AreaSelection.hitTest(CGPoint(x: 20, y: 20), rect: rect) == nil)
    }

    @Test func dragsOutAFreeRectInAnyDirection() {
        let drawn = AreaSelection.rect(from: CGPoint(x: 300, y: 300), to: CGPoint(x: 100, y: 200), aspect: nil, bounds: bounds)
        #expect(drawn == CGRect(x: 100, y: 200, width: 200, height: 100))
    }

    @Test func dragsOutAnAspectLockedRectInsideBounds() {
        let drawn = AreaSelection.rect(from: CGPoint(x: 1200, y: 700), to: CGPoint(x: 1600, y: 710), aspect: 16.0 / 9.0, bounds: bounds)
        #expect(isClose(drawn.width / drawn.height, 16.0 / 9.0, tolerance: 1e-9))
        #expect(drawn.minX == 1200 && drawn.minY == 700)
        #expect(drawn.maxX <= bounds.maxX + 1e-9 && drawn.maxY <= bounds.maxY + 1e-9)
    }

    @Test func freeResizeKeepsTheOppositeCorner() {
        let resized = AreaSelection.resize(rect, handle: .bottomRight, to: CGPoint(x: 700, y: 650), aspect: nil, bounds: bounds)
        #expect(resized == CGRect(x: 100, y: 100, width: 600, height: 550))
        let left = AreaSelection.resize(rect, handle: .left, to: CGPoint(x: 50, y: 999), aspect: nil, bounds: bounds)
        #expect(left == CGRect(x: 50, y: 100, width: 450, height: 300))
    }

    @Test func resizeRespectsTheMinimumSize() {
        let resized = AreaSelection.resize(rect, handle: .topLeft, to: CGPoint(x: 499, y: 399), aspect: nil, bounds: bounds)
        #expect(resized.width == AreaSelection.minimumSize.width)
        #expect(resized.height == AreaSelection.minimumSize.height)
        #expect(resized.maxX == rect.maxX && resized.maxY == rect.maxY)
    }

    @Test func aspectLockedCornerResizeKeepsTheShape() {
        let aspect: CGFloat = 16.0 / 9.0
        let start = CGRect(x: 100, y: 100, width: 320, height: 180)
        let resized = AreaSelection.resize(start, handle: .bottomRight, to: CGPoint(x: 900, y: 200), aspect: aspect, bounds: bounds)
        #expect(isClose(resized.width / resized.height, aspect, tolerance: 1e-9))
        #expect(resized.origin == start.origin)
        #expect(isClose(resized.width, 800))
        // Can't grow past the display: stops at the bottom edge.
        let huge = AreaSelection.resize(start, handle: .bottomRight, to: CGPoint(x: 5000, y: 5000), aspect: aspect, bounds: bounds)
        #expect(huge.maxX <= bounds.maxX + 1e-9 && huge.maxY <= bounds.maxY + 1e-9)
        #expect(isClose(huge.width / huge.height, aspect, tolerance: 1e-9))
    }

    @Test func aspectLockedEdgeResizeGrowsAroundTheCentre() {
        let aspect: CGFloat = 1
        let start = CGRect(x: 200, y: 200, width: 200, height: 200)
        let resized = AreaSelection.resize(start, handle: .right, to: CGPoint(x: 500, y: 300), aspect: aspect, bounds: bounds)
        #expect(isClose(resized.width, 300))
        #expect(isClose(resized.height, 300))
        #expect(resized.minX == 200)
        #expect(isClose(resized.midY, start.midY))
    }

    @Test func moveStopsAtTheEdges() {
        let moved = AreaSelection.move(rect, by: CGSize(width: -500, height: 2000), within: bounds)
        #expect(moved == CGRect(x: 0, y: 600, width: 400, height: 300))
    }

    @Test func presetsReshapeAroundTheCentre() {
        let square = AreaSelection.apply(.square, to: rect, scale: 2, bounds: bounds)
        #expect(isClose(square.width, 400) && isClose(square.height, 400))
        #expect(isClose(square.midX, rect.midX))

        // 1920×1080 pixels on a 2x display is 960×540 points.
        let hd = AreaSelection.apply(.hd1080, to: rect, scale: 2, bounds: bounds)
        #expect(isClose(hd.width, 960) && isClose(hd.height, 540))
        #expect(hd.minX >= 0 && hd.minY >= 0)

        // Too big for the display at 1x: scaled down to fit, keeping 16:9.
        let big = AreaSelection.apply(.hd1080, to: rect, scale: 1, bounds: bounds)
        #expect(big.width <= bounds.width && big.height <= bounds.height)
        #expect(isClose(big.width / big.height, 16.0 / 9.0, tolerance: 1e-9))

        #expect(AreaSelection.apply(.free, to: rect, scale: 2, bounds: bounds) == rect)
    }

    @Test func unknownPresetsDecodeAsFreeform() throws {
        let decoded = try JSONDecoder().decode([AreaPreset].self, from: Data(#"["square","ultrawide"]"#.utf8))
        #expect(decoded == [.square, .free])
    }
}

@Suite("Capture exclusion")
struct CaptureExclusionTests {
    private let windows = [
        CaptureExclusion.Window(windowID: 1, bundleID: CaptureExclusion.finderBundleID, layer: -2_147_483_603),
        CaptureExclusion.Window(windowID: 2, bundleID: CaptureExclusion.finderBundleID, layer: 0),
        CaptureExclusion.Window(windowID: 3, bundleID: "com.apple.Safari", layer: 0),
        CaptureExclusion.Window(windowID: 4, bundleID: CaptureExclusion.notificationCenterBundleID, layer: 23)
    ]

    @Test func alwaysLeavesOutTheAppItself() {
        let plan = CaptureExclusion.plan(ownBundleID: "app.test", windows: windows, hideDesktopIcons: false, hideNotifications: false)
        #expect(plan.excludedBundleIDs == ["app.test"])
        #expect(plan.exceptedWindowIDs.isEmpty)
    }

    @Test func hidesNotifications() {
        let plan = CaptureExclusion.plan(ownBundleID: "app.test", windows: windows, hideDesktopIcons: false, hideNotifications: true)
        #expect(plan.excludedBundleIDs == ["app.test", CaptureExclusion.notificationCenterBundleID])
    }

    @Test func hidesDesktopIconsButKeepsFinderWindows() {
        let plan = CaptureExclusion.plan(ownBundleID: nil, windows: windows, hideDesktopIcons: true, hideNotifications: false)
        #expect(plan.excludedBundleIDs == [CaptureExclusion.finderBundleID])
        #expect(plan.exceptedWindowIDs == [2])
    }
}

@Suite("Camera bubble snapping")
struct CameraBubbleSnappingTests {
    @Test func snapsToTheNearestCorner() {
        let screen = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        #expect(CameraBubblePosition.nearest(to: CGPoint(x: -100, y: 100), in: screen) == .bottomRight)
        #expect(CameraBubblePosition.nearest(to: CGPoint(x: -1300, y: 100), in: screen) == .bottomLeft)
        #expect(CameraBubblePosition.nearest(to: CGPoint(x: -100, y: 800), in: screen) == .topRight)
        #expect(CameraBubblePosition.nearest(to: CGPoint(x: -1300, y: 800), in: screen) == .topLeft)
    }
}
