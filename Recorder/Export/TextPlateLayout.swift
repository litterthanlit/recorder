import AppKit
import CoreGraphics

/// How a text overlay is laid out: its font, wrapping and padding. Shared by the renderer
/// and the editor canvas, so the box you drag fits the text that's drawn.
enum TextPlateLayout {
    struct Layout {
        let string: NSAttributedString
        /// The wrapped text.
        let textSize: CGSize
        /// Around the text, inside the plate.
        let padding: CGSize
        let fontSize: CGFloat

        var size: CGSize {
            CGSize(width: textSize.width + padding.width * 2, height: textSize.height + padding.height * 2)
        }
    }

    /// Sizes are designed at 1080p; `unit` scales them (`CanvasLayout.referenceUnit`).
    static func layout(text: String, style: TextOverlay.Style, scale: Double, unit: CGFloat, maxWidth: CGFloat) -> Layout {
        let clampedScale = CGFloat(min(max(scale, 0.3), 4))
        let fontSize = max(6, style.baseFontSize * clampedScale * unit)
        let weight: NSFont.Weight
        let padding: CGSize
        switch style {
        case .title:
            weight = .bold
            padding = CGSize(width: 20 * unit, height: 14 * unit)
        case .caption:
            weight = .medium
            padding = CGSize(width: fontSize * 0.7, height: fontSize * 0.38)
        case .callout:
            weight = .semibold
            padding = CGSize(width: fontSize * 0.8, height: fontSize * 0.42)
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        if style == .title {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
            shadow.shadowBlurRadius = 12 * unit
            shadow.shadowOffset = NSSize(width: 0, height: -2 * unit)
            attributes[.shadow] = shadow
        }
        let string = NSAttributedString(string: text, attributes: attributes)
        let bounds = string.boundingRect(
            with: CGSize(width: max(maxWidth - padding.width * 2, fontSize), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let textSize = CGSize(width: bounds.width.rounded(.up) + 2, height: bounds.height.rounded(.up) + 2)
        return Layout(string: string, textSize: textSize, padding: padding, fontSize: fontSize)
    }

    /// The overlay's layout on a canvas of `canvas` size.
    static func layout(for overlay: TextOverlay, text: String, canvas: CGSize) -> Layout {
        layout(
            text: text,
            style: overlay.style,
            scale: overlay.scale,
            unit: CanvasLayout.referenceUnit(for: canvas),
            maxWidth: canvas.width * 0.86
        )
    }

    /// Where the plate sits on the canvas, in Core Image space (bottom-left origin).
    static func frame(for overlay: TextOverlay, canvas: CGSize) -> CGRect {
        let text = overlay.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let size = layout(for: overlay, text: text.isEmpty ? " " : text, canvas: canvas).size
        return OverlayLayout.centeredFrame(
            size: size,
            normalizedCenter: overlay.center,
            canvas: canvas,
            margin: 16 * CanvasLayout.referenceUnit(for: canvas)
        )
    }

    /// The same, in view coordinates (top-left origin).
    static func viewFrame(for overlay: TextOverlay, canvas: CGSize) -> CGRect {
        let plate = frame(for: overlay, canvas: canvas)
        return CGRect(x: plate.minX, y: canvas.height - plate.maxY, width: plate.width, height: plate.height)
    }
}
