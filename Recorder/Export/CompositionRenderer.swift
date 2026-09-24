import AppKit
import CoreImage
import CoreVideo
import Foundation

struct CompositionRenderSettings: Equatable {
    var exportStyle: ExportStyle
    var zoomPreset: ZoomPreset
    var cursorEvents: [CursorEvent]
    var clickEvents: [ClickEvent]
    var sourceWidth: CGFloat
    var sourceHeight: CGFloat
    var drawCursor: Bool
    /// Placement of the separately recorded camera. Only drawn when a camera frame is
    /// passed to `renderImage` / `renderFrame`.
    var camera = CameraOverlayStyle()
    /// Source pixels per screen point (the capture's backing scale factor), so the
    /// smoothed cursor is drawn at the size the real cursor had on screen.
    var sourcePixelsPerPoint: CGFloat = 1
}

/// Composites one output frame: zoom crop, click ripples, cursor, background frame,
/// spotlight, camera bubble, and watermark.
///
/// Per-frame work is Core Image generators, transforms, and blends, so it runs on the
/// GPU. The few things that need CPU drawing (the cursor arrow, watermark text, and the
/// rounded background frame) are rasterized once and reused until what they depend on
/// changes, instead of being redrawn at full resolution every frame.
///
/// Not thread-safe: use each renderer from one queue.
final class CompositionRenderer {
    private let ciContext: CIContext
    private var interpolator: ZoomInterpolator
    private var settings: CompositionRenderSettings
    private let cursorSmoother = CursorPathSmoother()
    private var smoothedCursorEvents: [CursorEvent]
    private var rippleEvaluator: ClickRippleEvaluator
    private var motionFX: MotionFXSettings

    private var cursorSprite: CursorSprite?
    private var cachedWatermark: (text: String, image: CIImage)?
    private var cachedBackdrop: (key: BackdropKey, layers: BackdropLayers)?

    private static let workingColorSpace = CGColorSpace(name: CGColorSpace.sRGB)

    init(keyframes: [ZoomKeyframe], settings: CompositionRenderSettings, ciContext: CIContext? = nil) {
        // Every frame is different, so caching intermediates only costs memory.
        self.ciContext = ciContext ?? CIContext(options: [
            .useSoftwareRenderer: false,
            .cacheIntermediates: false
        ])
        self.settings = settings
        self.motionFX = settings.zoomPreset.motionFX
        self.interpolator = ZoomInterpolator(
            keyframes: keyframes,
            springEnabled: settings.exportStyle.springCameraEnabled,
            springSettings: settings.zoomPreset.motionFX.spring
        )
        self.rippleEvaluator = ClickRippleEvaluator(settings: settings.zoomPreset.motionFX)
        self.smoothedCursorEvents = Self.cursorPath(for: settings, smoother: cursorSmoother)
    }

    func update(keyframes: [ZoomKeyframe], settings: CompositionRenderSettings) {
        let cursorInputsChanged = settings.cursorEvents != self.settings.cursorEvents
            || settings.clickEvents != self.settings.clickEvents
            || settings.exportStyle.cursorSmoothingEnabled != self.settings.exportStyle.cursorSmoothingEnabled

        self.settings = settings
        self.motionFX = settings.zoomPreset.motionFX
        interpolator = ZoomInterpolator(
            keyframes: keyframes,
            springEnabled: settings.exportStyle.springCameraEnabled,
            springSettings: settings.zoomPreset.motionFX.spring
        )
        rippleEvaluator = ClickRippleEvaluator(settings: settings.zoomPreset.motionFX)
        if cursorInputsChanged {
            smoothedCursorEvents = Self.cursorPath(for: settings, smoother: cursorSmoother)
        }
    }

    func cropRect(at time: TimeInterval) -> NormalizedRect {
        interpolator.cropRect(at: time)
    }

    func renderImage(
        source: CIImage,
        camera: CIImage? = nil,
        at time: TimeInterval,
        outputWidth: Int,
        outputHeight: Int
    ) -> CIImage {
        let sourceWidth = settings.sourceWidth
        let sourceHeight = settings.sourceHeight
        let cropRect = interpolator.cropRect(at: time)

        var decorated = source
        if settings.exportStyle.clickRipplesEnabled {
            decorated = compositeRipples(onto: decorated, at: time)
        }

        if settings.drawCursor {
            decorated = compositeCursor(onto: decorated, at: time)
        }

        let cropX = cropRect.x * sourceWidth
        let cropY = cropRect.y * sourceHeight
        let cropW = cropRect.width * sourceWidth
        let cropH = cropRect.height * sourceHeight
        let cropped = decorated.cropped(to: CGRect(x: cropX, y: cropY, width: cropW, height: cropH))
        let croppedExtent = cropped.extent

        let fitted = fitContent(
            cropped,
            croppedExtent: croppedExtent,
            outputWidth: outputWidth,
            outputHeight: outputHeight
        )

        var finalImage: CIImage
        if settings.exportStyle.backgroundEnabled {
            finalImage = compositeOnBackground(
                fitted.image,
                contentFrame: fitted.frame,
                outputWidth: outputWidth,
                outputHeight: outputHeight
            )
        } else {
            finalImage = centerInCanvas(fitted.image, outputWidth: outputWidth, outputHeight: outputHeight)
        }

        if settings.exportStyle.cursorSpotlightEnabled,
           let cursorLocation = cursorLocation(at: time),
           let outputPoint = outputPoint(
                forSource: cursorLocation,
                cropRect: cropRect,
                contentFrame: fitted.frame,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight
           ) {
            finalImage = applySpotlight(
                to: finalImage,
                at: outputPoint,
                outputWidth: outputWidth,
                outputHeight: outputHeight
            )
        }

        // Drawn in output space after zoom and spotlight: the bubble stays put and sharp
        // while the screen content moves underneath it.
        if settings.camera.isVisible, let camera {
            finalImage = compositeCameraBubble(camera, onto: finalImage, contentFrame: fitted.frame)
        }

        if settings.exportStyle.watermarkEnabled {
            let bubble = settings.camera.isVisible && camera != nil
                ? CameraBubbleLayout.frame(in: fitted.frame.size, position: settings.camera.position, size: settings.camera.size)
                    .offsetBy(dx: fitted.frame.minX, dy: fitted.frame.minY)
                : nil
            finalImage = compositeWatermark(
                onto: finalImage,
                canvas: CGSize(width: outputWidth, height: outputHeight),
                avoiding: bubble
            )
        }

        return finalImage.cropped(to: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
    }

    /// Renders one composited frame.
    /// - Parameter pool: when given (e.g. an asset writer adaptor's pool), output buffers
    ///   are recycled from it instead of allocated per frame.
    func renderFrame(
        pixelBuffer: CVPixelBuffer,
        cameraBuffer: CVPixelBuffer? = nil,
        at time: TimeInterval,
        outputWidth: Int,
        outputHeight: Int,
        pool: CVPixelBufferPool? = nil
    ) throws -> CVPixelBuffer {
        let inputImage = CIImage(cvPixelBuffer: pixelBuffer)
        let finalImage = renderImage(
            source: inputImage,
            camera: cameraBuffer.map { CIImage(cvPixelBuffer: $0) },
            at: time,
            outputWidth: outputWidth,
            outputHeight: outputHeight
        )

        var outputBuffer: CVPixelBuffer?
        let status: CVReturn
        if let pool {
            status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outputBuffer)
        } else {
            status = Self.createIOSurfaceBuffer(width: outputWidth, height: outputHeight, buffer: &outputBuffer)
        }

        guard status == kCVReturnSuccess, let outputBuffer else {
            throw VideoExporterError.bufferCreationFailed
        }

        ciContext.render(finalImage, to: outputBuffer)
        return outputBuffer
    }

    // MARK: - Layout

    private struct FittedContent {
        let image: CIImage
        let frame: CGRect
    }

    private func fitContent(
        _ image: CIImage,
        croppedExtent: CGRect,
        outputWidth: Int,
        outputHeight: Int
    ) -> FittedContent {
        let padding = settings.exportStyle.backgroundEnabled
            ? CGFloat(outputWidth) * settings.exportStyle.paddingFraction
            : 0
        let availableWidth = CGFloat(outputWidth) - padding * 2
        let availableHeight = CGFloat(outputHeight) - padding * 2
        guard croppedExtent.width > 0, croppedExtent.height > 0, availableWidth > 0, availableHeight > 0 else {
            return FittedContent(image: image, frame: .zero)
        }

        let scale = min(availableWidth / croppedExtent.width, availableHeight / croppedExtent.height)
        let scaledWidth = croppedExtent.width * scale
        let scaledHeight = croppedExtent.height * scale

        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let origin = CGPoint(
            x: padding + (availableWidth - scaledWidth) / 2,
            y: padding + (availableHeight - scaledHeight) / 2
        )
        let translated = scaled.transformed(
            by: CGAffineTransform(
                translationX: origin.x - scaled.extent.origin.x,
                y: origin.y - scaled.extent.origin.y
            )
        )

        return FittedContent(
            image: translated,
            frame: CGRect(x: origin.x, y: origin.y, width: scaledWidth, height: scaledHeight)
        )
    }

    private func centerInCanvas(_ image: CIImage, outputWidth: Int, outputHeight: Int) -> CIImage {
        let extent = image.extent
        let origin = CGPoint(
            x: (CGFloat(outputWidth) - extent.width) / 2 - extent.origin.x,
            y: (CGFloat(outputHeight) - extent.height) / 2 - extent.origin.y
        )
        return image.transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
            .cropped(to: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
    }

    // MARK: - Background frame

    /// The gradient, drop shadow, and rounded-corner mask only change with the layout,
    /// so they are rendered once into GPU-resident buffers and reused every frame.
    private struct BackdropLayers {
        let background: CIImage
        let contentMask: CIImage
    }

    private struct BackdropKey: Equatable {
        let outputWidth: Int
        let outputHeight: Int
        /// Content frame and corner radius in hundredths of a pixel, so floating-point
        /// noise in the per-frame layout math doesn't defeat the cache.
        let frame: [Int]
        let cornerRadius: Int
        let shadowEnabled: Bool

        init(outputWidth: Int, outputHeight: Int, contentFrame: CGRect, cornerRadius: CGFloat, shadowEnabled: Bool) {
            func quantized(_ value: CGFloat) -> Int { Int((value * 100).rounded()) }
            self.outputWidth = outputWidth
            self.outputHeight = outputHeight
            frame = [contentFrame.minX, contentFrame.minY, contentFrame.width, contentFrame.height].map(quantized)
            self.cornerRadius = quantized(cornerRadius)
            self.shadowEnabled = shadowEnabled
        }
    }

    private func compositeOnBackground(
        _ content: CIImage,
        contentFrame: CGRect,
        outputWidth: Int,
        outputHeight: Int
    ) -> CIImage {
        let layers = backdropLayers(contentFrame: contentFrame, outputWidth: outputWidth, outputHeight: outputHeight)
        let maskedContent = content.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputMaskImageKey: layers.contentMask
        ])
        return maskedContent.composited(over: layers.background)
    }

    private func backdropLayers(contentFrame: CGRect, outputWidth: Int, outputHeight: Int) -> BackdropLayers {
        let style = settings.exportStyle
        let key = BackdropKey(
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            contentFrame: contentFrame,
            cornerRadius: style.cornerRadius,
            shadowEnabled: style.shadowEnabled
        )
        if let cachedBackdrop, cachedBackdrop.key == key {
            return cachedBackdrop.layers
        }

        let outputSize = CGSize(width: outputWidth, height: outputHeight)
        let outputRect = CGRect(origin: .zero, size: outputSize)

        var background = makeBackgroundGradient(in: outputRect)
        if style.shadowEnabled {
            // Core Image space is y-up, so a negative offset puts the shadow below.
            let shadowMask = roundedRectMask(
                rect: contentFrame.offsetBy(dx: 0, dy: -6),
                radius: style.cornerRadius,
                canvasSize: outputSize
            )
            let shadow = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.35))
                .cropped(to: outputRect)
                .applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputMaskImageKey: shadowMask
                        .clampedToExtent()
                        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 16])
                        .cropped(to: outputRect)
                ])
            background = shadow.composited(over: background)
        }

        let contentMask = roundedRectMask(rect: contentFrame, radius: style.cornerRadius, canvasSize: outputSize)
        let layers = BackdropLayers(
            background: materialize(background, size: outputSize),
            contentMask: materialize(contentMask, size: outputSize)
        )
        cachedBackdrop = (key, layers)
        return layers
    }

    private func makeBackgroundGradient(in rect: CGRect) -> CIImage {
        guard let filter = CIFilter(name: "CILinearGradient") else {
            return CIImage(color: CIColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1)).cropped(to: rect)
        }
        filter.setValue(CIVector(x: rect.midX, y: rect.maxY), forKey: "inputPoint0")
        filter.setValue(CIVector(x: rect.midX, y: rect.minY), forKey: "inputPoint1")
        filter.setValue(CIColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1), forKey: "inputColor0")
        filter.setValue(CIColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1), forKey: "inputColor1")
        return (filter.outputImage ?? CIImage.empty()).cropped(to: rect)
    }

    /// Anti-aliased white rounded rectangle on transparent. `rect` is in Core Image space
    /// (bottom-left origin), which matches an unflipped bitmap context.
    private func roundedRectMask(rect: CGRect, radius: CGFloat, canvasSize: CGSize) -> CIImage {
        renderBitmap(size: canvasSize) { context in
            context.setFillColor(NSColor.white.cgColor)
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            context.addPath(path.cgPath)
            context.fillPath()
        }
    }

    // MARK: - Watermark

    private func compositeWatermark(onto image: CIImage, canvas: CGSize, avoiding bubble: CGRect?) -> CIImage {
        let text = settings.exportStyle.watermarkText
        let textImage: CIImage
        if let cachedWatermark, cachedWatermark.text == text {
            textImage = cachedWatermark.image
        } else {
            textImage = makeWatermarkImage(text: text)
            cachedWatermark = (text, textImage)
        }

        // Bottom-right corner, 24 px in from each edge, unless the camera bubble is there.
        let origin = OverlayLayout.watermarkOrigin(
            size: textImage.extent.size,
            canvas: canvas,
            margin: 24,
            avoiding: bubble
        )
        return textImage
            .transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
            .composited(over: image)
    }

    /// Just the text, in a bitmap the size of the text.
    private func makeWatermarkImage(text: String) -> CIImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.55)
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        return renderBitmap(size: CGSize(width: size.width + 2, height: size.height + 2)) { context in
            // AppKit string drawing targets NSGraphicsContext.current, which is nil on
            // the render queues unless we install one around the bitmap context.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            (text as NSString).draw(at: CGPoint(x: 1, y: 1), withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    // MARK: - Camera bubble

    /// Circular camera bubble in a corner of the video frame, with a white rim and a soft
    /// shadow.
    private func compositeCameraBubble(_ camera: CIImage, onto image: CIImage, contentFrame: CGRect) -> CIImage {
        guard contentFrame.width > 0, contentFrame.height > 0,
              camera.extent.width > 0, camera.extent.height > 0
        else { return image }

        let bubble = CameraBubbleLayout.frame(in: contentFrame.size, position: settings.camera.position, size: settings.camera.size)
            .offsetBy(dx: contentFrame.minX, dy: contentFrame.minY)
        let radius = bubble.width / 2
        let center = CGPoint(x: bubble.midX, y: bubble.midY)

        // Aspect-fill the camera frame into the bubble's square.
        let extent = camera.extent
        let scale = max(bubble.width / extent.width, bubble.height / extent.height)
        let placed = camera
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(
                translationX: center.x - extent.width * scale / 2,
                y: center.y - extent.height * scale / 2
            ))
            .cropped(to: bubble)

        let rimWidth = max(2, radius * 0.045)
        let rimRadius = radius + rimWidth
        let white = CIColor(red: 1, green: 1, blue: 1, alpha: 1)

        let shadow = disc(
            center: CGPoint(x: center.x, y: center.y - rimWidth * 1.5),
            radius: rimRadius,
            color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.35)
        )
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: rimWidth * 3])
        .cropped(to: bubble.insetBy(dx: -rimWidth * 12, dy: -rimWidth * 12))

        let rim = disc(center: center, radius: rimRadius, color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.92))

        let face = placed.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputMaskImageKey: disc(center: center, radius: radius, color: white)
        ])

        return face
            .composited(over: rim)
            .composited(over: shadow)
            .composited(over: image)
    }

    // MARK: - Cursor

    /// The arrow is rasterized once at source pixel density; each frame only moves and
    /// scales it, instead of drawing a full-resolution bitmap per frame.
    private struct CursorSprite {
        let image: CIImage
        /// Arrow tip in `image` coordinates.
        let tip: CGPoint
        /// Sprite pixels per point of arrow.
        let density: CGFloat
    }

    private func cursorLocation(at time: TimeInterval) -> CGPoint? {
        cursorSmoother.location(at: time, in: smoothedCursorEvents)
    }

    private func compositeCursor(onto image: CIImage, at time: TimeInterval) -> CIImage {
        guard let cursorLocation = cursorLocation(at: time) else {
            return image
        }

        let clickScale: CGFloat
        if settings.exportStyle.cursorScaleOnClickEnabled {
            clickScale = CursorClickScale.scale(at: time, clicks: settings.clickEvents, settings: motionFX)
        } else {
            clickScale = 1
        }

        let pointScale = max(settings.sourcePixelsPerPoint, 1)
        let sprite: CursorSprite
        if let cursorSprite, cursorSprite.density == pointScale {
            sprite = cursorSprite
        } else {
            sprite = makeCursorSprite(density: pointScale)
            cursorSprite = sprite
        }

        // Sprite pixels -> source pixels, scaled about the tip, tip placed on the cursor.
        let scale = pointScale * clickScale / sprite.density
        let placed = sprite.image
            .transformed(by: CGAffineTransform(translationX: -sprite.tip.x, y: -sprite.tip.y))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: cursorLocation.x, y: cursorLocation.y))

        return placed.composited(over: image)
    }

    private func makeCursorSprite(density: CGFloat) -> CursorSprite {
        // Arrow spans 12.5 × 18 points (plus a 1.5/2 point shadow offset); keep a margin
        // for the stroke and shadow.
        let margin: CGFloat = 2
        let pointSize = CGSize(width: 14 + margin * 2, height: 20 + margin * 2)
        let pixelSize = CGSize(width: pointSize.width * density, height: pointSize.height * density)

        let image = renderBitmap(size: pixelSize) { context in
            // Draw top-down in points so the path reads like the arrow it describes.
            context.translateBy(x: 0, y: pixelSize.height)
            context.scaleBy(x: density, y: -density)
            context.translateBy(x: margin, y: margin)

            let shadow = CGMutablePath()
            appendCursorPath(shadow, at: CGPoint(x: 1.5, y: 2))
            context.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
            context.addPath(shadow)
            context.fillPath()

            let path = CGMutablePath()
            appendCursorPath(path, at: .zero)
            context.setFillColor(NSColor.white.cgColor)
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.85).cgColor)
            context.setLineWidth(1.2)
            context.addPath(path)
            context.drawPath(using: .fillStroke)
        }

        // The tip sits `margin` points from the top-left; Core Image is y-up.
        let tip = CGPoint(x: margin * density, y: pixelSize.height - margin * density)
        return CursorSprite(image: image, tip: tip, density: density)
    }

    private func appendCursorPath(_ path: CGMutablePath, at origin: CGPoint) {
        path.move(to: CGPoint(x: origin.x, y: origin.y))
        path.addLine(to: CGPoint(x: origin.x, y: origin.y + 16))
        path.addLine(to: CGPoint(x: origin.x + 4.5, y: origin.y + 11.5))
        path.addLine(to: CGPoint(x: origin.x + 9, y: origin.y + 18))
        path.addLine(to: CGPoint(x: origin.x + 11, y: origin.y + 16.8))
        path.addLine(to: CGPoint(x: origin.x + 6.5, y: origin.y + 10.2))
        path.addLine(to: CGPoint(x: origin.x + 12.5, y: origin.y + 10.2))
        path.closeSubpath()
    }

    // MARK: - Click ripples

    private func compositeRipples(onto image: CIImage, at time: TimeInterval) -> CIImage {
        let ripples = rippleEvaluator.ripples(at: time, clicks: settings.clickEvents)
        guard !ripples.isEmpty else { return image }

        // Click locations are bottom-up, the same space as the source image.
        return ripples.reduce(image) { composed, ripple in
            let radius = motionFX.rippleRadius * (0.18 + 0.82 * ripple.progress)
            let alpha = (1 - ripple.progress) * (ripple.ring == 0 ? 0.7 : 0.42)
            let lineWidth: CGFloat = ripple.ring == 0 ? 3.2 : 2.2
            return ring(center: ripple.location, radius: radius, lineWidth: lineWidth, alpha: alpha)
                .composited(over: composed)
        }
    }

    /// White ring (annulus) centered on `radius`, `lineWidth` wide.
    private func ring(center: CGPoint, radius: CGFloat, lineWidth: CGFloat, alpha: CGFloat) -> CIImage {
        let outer = disc(
            center: center,
            radius: radius + lineWidth / 2,
            color: CIColor(red: 1, green: 1, blue: 1, alpha: alpha)
        )
        let innerRadius = radius - lineWidth / 2
        guard innerRadius > 0 else { return outer }
        let inner = disc(center: center, radius: innerRadius, color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
        // Keep the outer disc only where the inner disc isn't.
        return outer.applyingFilter("CISourceOutCompositing", parameters: [
            kCIInputBackgroundImageKey: inner
        ])
    }

    /// Filled disc with a soft one-and-a-half-pixel edge, transparent elsewhere.
    private func disc(center: CGPoint, radius: CGFloat, color: CIColor) -> CIImage {
        guard let filter = CIFilter(name: "CIRadialGradient") else {
            return CIImage.empty()
        }
        filter.setValue(CIVector(x: center.x, y: center.y), forKey: "inputCenter")
        filter.setValue(max(0, radius - 0.75), forKey: "inputRadius0")
        filter.setValue(radius + 0.75, forKey: "inputRadius1")
        filter.setValue(color, forKey: "inputColor0")
        filter.setValue(CIColor(red: color.red, green: color.green, blue: color.blue, alpha: 0), forKey: "inputColor1")
        let bounds = CGRect(
            x: center.x - radius - 2,
            y: center.y - radius - 2,
            width: radius * 2 + 4,
            height: radius * 2 + 4
        )
        return (filter.outputImage ?? CIImage.empty()).cropped(to: bounds)
    }

    // MARK: - Spotlight

    private func outputPoint(
        forSource point: CGPoint,
        cropRect: NormalizedRect,
        contentFrame: CGRect,
        sourceWidth: CGFloat,
        sourceHeight: CGFloat
    ) -> CGPoint? {
        let localX = (point.x / sourceWidth - cropRect.x) / max(cropRect.width, 0.0001)
        let localY = (point.y / sourceHeight - cropRect.y) / max(cropRect.height, 0.0001)
        guard localX >= 0, localX <= 1, localY >= 0, localY <= 1 else {
            return nil
        }
        return CGPoint(
            x: contentFrame.minX + localX * contentFrame.width,
            y: contentFrame.minY + localY * contentFrame.height
        )
    }

    private func applySpotlight(
        to image: CIImage,
        at point: CGPoint,
        outputWidth: Int,
        outputHeight: Int
    ) -> CIImage {
        let outputRect = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        guard let filter = CIFilter(name: "CIRadialGradient") else { return image }
        filter.setValue(CIVector(x: point.x, y: point.y), forKey: "inputCenter")
        filter.setValue(motionFX.spotlightInnerRadius, forKey: "inputRadius0")
        filter.setValue(motionFX.spotlightOuterRadius, forKey: "inputRadius1")
        filter.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: 1), forKey: "inputColor0")
        filter.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 1), forKey: "inputColor1")
        let mask = (filter.outputImage ?? CIImage.empty()).cropped(to: outputRect)
        let overlay = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: motionFX.spotlightStrength))
            .cropped(to: outputRect)
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputMaskImageKey: mask
            ])
        return overlay.composited(over: image)
    }

    // MARK: - Helpers

    private static func cursorPath(
        for settings: CompositionRenderSettings,
        smoother: CursorPathSmoother
    ) -> [CursorEvent] {
        settings.exportStyle.cursorSmoothingEnabled
            ? smoother.smooth(settings.cursorEvents, clicks: settings.clickEvents)
            : settings.cursorEvents
    }

    private static func createIOSurfaceBuffer(width: Int, height: Int, buffer: inout CVPixelBuffer?) -> CVReturn {
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
            &buffer
        )
    }

    /// Renders `image` once into a GPU-resident (IOSurface) buffer and returns an image
    /// backed by it, so reusing it costs no CPU work or texture upload per frame.
    private func materialize(_ image: CIImage, size: CGSize) -> CIImage {
        let width = max(Int(size.width.rounded(.up)), 1)
        let height = max(Int(size.height.rounded(.up)), 1)
        var buffer: CVPixelBuffer?
        guard Self.createIOSurfaceBuffer(width: width, height: height, buffer: &buffer) == kCVReturnSuccess,
              let buffer
        else {
            return image
        }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        ciContext.render(image.cropped(to: bounds), to: buffer, bounds: bounds, colorSpace: Self.workingColorSpace)
        if let colorSpace = Self.workingColorSpace {
            return CIImage(cvPixelBuffer: buffer, options: [.colorSpace: colorSpace])
        }
        return CIImage(cvPixelBuffer: buffer)
    }

    private func renderBitmap(size: CGSize, draw: (CGContext) -> Void) -> CIImage {
        let width = Int(size.width.rounded(.up))
        let height = Int(size.height.rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            return CIImage.empty()
        }

        draw(context)

        guard let cgImage = context.makeImage() else {
            return CIImage.empty()
        }
        return CIImage(cgImage: cgImage)
    }
}

private extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        for index in 0..<elementCount {
            let type = element(at: index, associatedPoints: &points)
            switch type {
            case .moveTo:
                path.move(to: points[0])
            case .lineTo:
                path.addLine(to: points[0])
            case .curveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closePath:
                path.closeSubpath()
            case .cubicCurveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo:
                path.addQuadCurve(to: points[1], control: points[0])
            @unknown default:
                break
            }
        }
        return path
    }
}
