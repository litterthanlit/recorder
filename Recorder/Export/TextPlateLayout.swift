import CoreGraphics
import CoreText
import Foundation

/// How a text overlay is laid out: its font, wrapping and padding. Shared by the renderer
/// and the editor canvas, so the box you drag fits the text that's drawn.
///
/// Uses CoreText and CoreGraphics exclusively so it is safe to call on background render,
/// export, and agent queues as well as the main thread.
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

    struct MeasuredLine {
        let line: CTLine
        let width: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
        let leading: CGFloat

        var size: CGSize {
            CGSize(width: width.rounded(.up), height: (ascent + descent + leading).rounded(.up))
        }
    }

    /// Normalized CoreText font weight trait values matching `NSFont.Weight`.
    enum FontWeight: CGFloat {
        case medium = 0.23
        case semibold = 0.30
        case bold = 0.40
    }

    /// Creates a system UI font of `size` and CoreText `weight`.
    static func systemFont(size: CGFloat, weight: FontWeight, monospacedDigits: Bool = false) -> CTFont {
        let clampedSize = max(6, size)
        let base = CTFontCreateUIFontForLanguage(.system, clampedSize, nil)
            ?? CTFontCreateWithName("HelveticaNeue" as CFString, clampedSize, nil)
        let traits: [CFString: Any] = [kCTFontWeightTrait: weight.rawValue]
        var attributes: [CFString: Any] = [kCTFontTraitsAttribute: traits]
        if monospacedDigits {
            let feature: [CFString: Any] = [
                kCTFontFeatureTypeIdentifierKey: kNumberSpacingType,
                kCTFontFeatureSelectorIdentifierKey: kMonospacedNumbersSelector
            ]
            attributes[kCTFontFeatureSettingsAttribute] = [feature]
        }
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(base), attributes as CFDictionary)
        return CTFontCreateCopyWithAttributes(base, clampedSize, nil, descriptor)
    }

    /// Measures a single line of text with CoreText for thread-safe drawing.
    static func measureLine(
        _ text: String,
        font: CTFont,
        color: CGColor,
        kern: CGFloat? = nil
    ) -> MeasuredLine {
        var attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: color
        ]
        if let kern {
            attributes[kCTKernAttributeName as NSAttributedString.Key] = kern
        }
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        return MeasuredLine(line: line, width: width, ascent: ascent, descent: descent, leading: leading)
    }

    /// Draws a measured single line into an unflipped (bottom-left origin) `CGContext`.
    static func drawLine(_ measured: MeasuredLine, at origin: CGPoint, in context: CGContext) {
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: origin.x, y: origin.y + measured.descent)
        CTLineDraw(measured.line, context)
        context.restoreGState()
    }

    /// Sizes are designed at 1080p; `unit` scales them (`CanvasLayout.referenceUnit`).
    static func layout(text: String, style: TextOverlay.Style, scale: Double, unit: CGFloat, maxWidth: CGFloat) -> Layout {
        let clampedScale = CGFloat(min(max(scale, 0.3), 4))
        let fontSize = max(6, style.baseFontSize * clampedScale * unit)
        let weight: FontWeight
        let padding: CGSize
        switch style {
        case .title:
            weight = .bold
            padding = CGSize(width: 20 * unit, height: 18 * unit)
        case .caption:
            weight = .medium
            padding = CGSize(width: fontSize * 0.7, height: fontSize * 0.38)
        case .callout:
            weight = .semibold
            padding = CGSize(width: fontSize * 0.8, height: fontSize * 0.42)
        }

        var alignment = CTTextAlignment.center
        var lineBreak = CTLineBreakMode.byWordWrapping
        let paragraphStyle = withUnsafeBytes(of: &alignment) { alignPtr in
            withUnsafeBytes(of: &lineBreak) { breakPtr in
                let settings = [
                    CTParagraphStyleSetting(
                        spec: .alignment,
                        valueSize: MemoryLayout<CTTextAlignment>.size,
                        value: alignPtr.baseAddress!
                    ),
                    CTParagraphStyleSetting(
                        spec: .lineBreakMode,
                        valueSize: MemoryLayout<CTLineBreakMode>.size,
                        value: breakPtr.baseAddress!
                    )
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }

        let font = systemFont(size: fontSize, weight: weight)
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: white,
            kCTParagraphStyleAttributeName as NSAttributedString.Key: paragraphStyle
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(string as CFAttributedString)
        let constraint = CGSize(width: max(maxWidth - padding.width * 2, fontSize), height: .greatestFiniteMagnitude)
        var fitRange = CFRange()
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil, constraint, &fitRange)
        let textSize = CGSize(width: suggested.width.rounded(.up) + 2, height: suggested.height.rounded(.up) + 2)
        return Layout(string: string, textSize: textSize, padding: padding, fontSize: fontSize)
    }

    /// `string` with only its first `count` characters showing: the rest are clear, so
    /// the text keeps its layout (and its plate its size) as it types on.
    static func revealing(_ string: NSAttributedString, characters count: Int) -> NSAttributedString {
        let text = string.string
        guard count < text.count else { return string }
        let start = text.index(text.startIndex, offsetBy: max(count, 0))
        let hidden = NSRange(start..<text.endIndex, in: text)
        let result = NSMutableAttributedString(attributedString: string)
        let clear = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
        result.addAttribute(kCTForegroundColorAttributeName as NSAttributedString.Key, value: clear, range: hidden)
        return result
    }

    /// Draws the laid-out text into an unflipped (bottom-left origin) `CGContext`.
    static func draw(
        _ layout: Layout,
        revealed: Int? = nil,
        style: TextOverlay.Style,
        unit: CGFloat,
        in context: CGContext,
        rect: CGRect
    ) {
        let attrString = revealed.map { revealing(layout.string, characters: $0) } ?? layout.string
        let framesetter = CTFramesetterCreateWithAttributedString(attrString as CFAttributedString)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)
        context.saveGState()
        context.textMatrix = .identity
        if style == .title {
            context.setShadow(
                offset: CGSize(width: 0, height: -2 * unit),
                blur: 12 * unit,
                color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45)
            )
        }
        CTFrameDraw(frame, context)
        context.restoreGState()
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
