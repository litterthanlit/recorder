import AppKit

/// Images of the system arrow, I-beam and pointing-hand cursors, rasterized once on the
/// main thread (AppKit's cursors belong to it) so render queues can draw the recorded
/// cursor exactly as macOS does.
final class SystemCursorImages: @unchecked Sendable {
    struct Sprite {
        let image: CGImage
        /// Hot spot in sprite pixels, top-left origin.
        let hotSpot: CGPoint
        /// Sprite pixels per cursor point.
        let density: CGFloat
    }

    static let shared = SystemCursorImages()

    /// Rendered at 4 pixels per point so a zoomed-in cursor stays sharp.
    static let density: CGFloat = 4

    private let lock = NSLock()
    private var sprites: [CursorKind: Sprite] = [:]

    /// Call on the main thread before rendering (editor open, export start).
    @MainActor
    func load() {
        lock.lock()
        let isLoaded = !sprites.isEmpty
        lock.unlock()
        guard !isLoaded else { return }

        var made: [CursorKind: Sprite] = [:]
        for kind in CursorKind.allCases {
            let cursor: NSCursor
            switch kind {
            case .arrow: cursor = .arrow
            case .iBeam: cursor = .iBeam
            case .pointingHand: cursor = .pointingHand
            }
            if let sprite = Self.rasterize(cursor) {
                made[kind] = sprite
            }
        }
        lock.lock()
        sprites = made
        lock.unlock()
    }

    func sprite(for kind: CursorKind) -> Sprite? {
        lock.lock()
        defer { lock.unlock() }
        return sprites[kind] ?? sprites[.arrow]
    }

    /// Room around the cursor for its shadow, in points.
    private static let shadowMargin: CGFloat = 3

    /// Draws the cursor with the soft shadow the window server gives the real one.
    @MainActor
    private static func rasterize(_ cursor: NSCursor) -> Sprite? {
        let size = cursor.image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let margin = shadowMargin
        let width = Int(((size.width + margin * 2) * density).rounded(.up))
        let height = Int(((size.height + margin * 2) * density).rounded(.up))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setShadow(
            offset: CGSize(width: 0, height: -1 * density),
            blur: 2.5 * density,
            color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35)
        )
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        cursor.image.draw(in: CGRect(
            x: margin * density,
            y: margin * density,
            width: size.width * density,
            height: size.height * density
        ))
        NSGraphicsContext.restoreGraphicsState()

        guard let image = context.makeImage() else { return nil }
        // NSCursor's hot spot has a top-left origin, like the sprite's.
        return Sprite(
            image: image,
            hotSpot: CGPoint(x: (cursor.hotSpot.x + margin) * density, y: (cursor.hotSpot.y + margin) * density),
            density: density
        )
    }
}
