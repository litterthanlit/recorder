import CoreGraphics
import Foundation

/// Which frames an agent sees and how big: frames go back as JPEG images, so they're
/// kept within what a model reads well and a tool result carries comfortably.
enum FrameSampling {
    /// Longest side of any image sent back.
    static let maximumLongEdge = 1568
    static let maximumSheetTiles = 24
    static let maximumFrames = 6
    static let defaultSheetCount = 12
    static let defaultFrameCount = 4
    static let jpegQuality = 0.7

    /// `count` times spread through `span`, each in the middle of its share (so neither
    /// end, often a still frame, is picked).
    static func evenlySpaced(count: Int, in span: TimeSpan) -> [TimeInterval] {
        guard count > 0 else { return [] }
        guard span.duration > 0 else { return [span.start] }
        let step = span.duration / Double(count)
        return (0..<count).map { span.start + step * (Double($0) + 0.5) }
    }

    /// `size` scaled down to fit `longEdge` (never up), in whole pixels.
    static func fitted(_ size: CGSize, longEdge: CGFloat) -> CGSize {
        let long = max(size.width, size.height)
        guard long > longEdge, long > 0 else {
            return CGSize(width: max(1, size.width.rounded()), height: max(1, size.height.rounded()))
        }
        let scale = longEdge / long
        return CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
    }

    /// A contact sheet: tiles in a grid, each with a label strip under it.
    struct SheetLayout: Equatable {
        let columns: Int
        let rows: Int
        let tileSize: CGSize
        let labelHeight: CGFloat
        let gap: CGFloat

        var size: CGSize {
            CGSize(
                width: CGFloat(columns) * tileSize.width + CGFloat(columns + 1) * gap,
                height: CGFloat(rows) * (tileSize.height + labelHeight) + CGFloat(rows + 1) * gap
            )
        }

        /// Where tile `index` goes, top-left origin; its label sits right under it.
        func tileFrame(_ index: Int) -> CGRect {
            let column = index % columns
            let row = index / columns
            return CGRect(
                x: gap + CGFloat(column) * (tileSize.width + gap),
                y: gap + CGFloat(row) * (tileSize.height + labelHeight + gap),
                width: tileSize.width,
                height: tileSize.height
            )
        }
    }

    /// The grid that gives `count` tiles of `tileAspect` (width ÷ height) the most room
    /// within a `longEdge` square.
    static func sheetLayout(
        count: Int,
        tileAspect: CGFloat,
        longEdge: CGFloat = CGFloat(maximumLongEdge),
        labelHeight: CGFloat = 22,
        gap: CGFloat = 6
    ) -> SheetLayout {
        let count = max(count, 1)
        let aspect = tileAspect > 0 && tileAspect.isFinite ? tileAspect : 16.0 / 9.0
        var best: SheetLayout?
        for columns in 1...count {
            let rows = (count + columns - 1) / columns
            // As wide as the sheet allows, then shrunk if the rows don't fit.
            var width = (longEdge - CGFloat(columns + 1) * gap) / CGFloat(columns)
            var height = width / aspect
            if CGFloat(rows) * (height + labelHeight) + CGFloat(rows + 1) * gap > longEdge {
                height = (longEdge - CGFloat(rows + 1) * gap) / CGFloat(rows) - labelHeight
                width = height * aspect
            }
            guard width >= 16, height >= 9 else { continue }
            let layout = SheetLayout(
                columns: columns,
                rows: rows,
                tileSize: CGSize(width: width.rounded(.down), height: height.rounded(.down)),
                labelHeight: labelHeight,
                gap: gap
            )
            if let current = best, current.tileSize.width * current.tileSize.height >= layout.tileSize.width * layout.tileSize.height {
                continue
            }
            best = layout
        }
        return best ?? SheetLayout(
            columns: 1,
            rows: count,
            tileSize: CGSize(width: 160, height: 90),
            labelHeight: labelHeight,
            gap: gap
        )
    }
}
