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
    /// Whether there's a recorded cursor to draw (the real one was hidden from capture).
    var drawCursor: Bool
    /// Placement of the separately recorded camera. Only drawn when a camera frame is
    /// passed to `renderImage` / `renderFrame`.
    var camera = CameraOverlayStyle()
    /// Source pixels per screen point (the capture's backing scale factor), so the
    /// smoothed cursor is drawn at the size the real cursor had on screen.
    var sourcePixelsPerPoint: CGFloat = 1
    /// Key presses for the keystroke overlay (source time).
    var keystrokes: [KeystrokeEvent] = []
    /// When the cursor changed shape (source time).
    var cursorKinds: [CursorKindEvent] = []
    var textOverlays: [TextOverlay] = []
    var blurRegions: [BlurRegion] = []
    /// The picture for an image background, inside the project bundle.
    var backgroundImageURL: URL?
    /// The part of the recording shown at rest (normalized, bottom-left origin); `nil`
    /// shows all of it. See `SourceCrop`.
    var sourceCrop: CGRect?
}

extension CompositionRenderSettings {
    /// Everything `project` draws, with `editSettings` in place of its saved ones.
    init(project: RecorderProject, editSettings: ProjectEditSettings) {
        var edited = project
        edited.editSettings = editSettings
        self.init(
            exportStyle: editSettings.exportStyle,
            zoomPreset: editSettings.zoomPreset,
            cursorEvents: project.cursorEvents,
            clickEvents: project.clickEvents,
            sourceWidth: CGFloat(project.metadata.width),
            sourceHeight: CGFloat(project.metadata.height),
            drawCursor: !project.cursorEvents.isEmpty,
            camera: editSettings.camera,
            sourcePixelsPerPoint: project.metadata.scaleFactor,
            keystrokes: project.inputs.keystrokes,
            cursorKinds: project.inputs.cursorKinds,
            textOverlays: editSettings.textOverlays,
            blurRegions: editSettings.blurRegions,
            backgroundImageURL: edited.backgroundImageURL,
            sourceCrop: editSettings.sourceCrop
        )
    }
}

/// Composites one output frame.
///
/// In source space (so they zoom with the recording): blurred regions, click ripples,
/// and the cursor. Then the zoom crop, fitted into the canvas on its background with
/// rounded corners and a shadow. In output space (so they stay put and sharp): the
/// spotlight, camera, text, keystrokes, and watermark.
///
/// Per-frame work is Core Image generators, transforms, and blends, so it runs on the
/// GPU. The things that need CPU drawing (text, pills, masks, the background) are
/// rasterized once and reused until what they depend on changes.
///
/// Not thread-safe: use each renderer from one queue.
final class CompositionRenderer {
    private let ciContext: CIContext
    private var interpolator: ZoomInterpolator
    private var settings: CompositionRenderSettings
    private let cursorSmoother = CursorPathSmoother()
    private var smoothedCursorEvents: [CursorEvent]
    /// When the pointer moved or clicked, for hiding it while idle.
    private var cursorActivity: [TimeInterval]
    private var keystrokePills: [KeystrokePill]
    private var rippleEvaluator: ClickRippleEvaluator
    private var motionFX: MotionFXSettings

    private var systemCursors: [CursorKind: CursorSprite] = [:]
    private var fallbackCursor: CursorSprite?
    private var cachedWatermark: (key: String, image: CIImage)?
    private var cachedBackdrop: (key: BackdropKey, layers: BackdropLayers)?
    private var cachedCamera: (key: CameraKey, layers: CameraLayers)?
    private var cachedBackgroundImage: (url: URL, image: CIImage?)?
    private var textCache: [String: CIImage] = [:]
    private var pillCache: [String: CIImage] = [:]

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    /// Brand violet, for callouts.
    private static let accent = RGBAColor(hex: "6E56CF")

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
            springSettings: settings.zoomPreset.motionFX.spring,
            base: SourceCrop.base(settings.sourceCrop)
        )
        self.rippleEvaluator = ClickRippleEvaluator(settings: settings.zoomPreset.motionFX)
        self.smoothedCursorEvents = Self.cursorPath(for: settings, smoother: cursorSmoother)
        self.cursorActivity = CursorVisibility.activityTimes(cursor: settings.cursorEvents, clicks: settings.clickEvents)
        self.keystrokePills = KeystrokeOverlayTimeline.pills(
            from: settings.keystrokes,
            filter: settings.exportStyle.keystrokes.filter
        )
    }

    func update(keyframes: [ZoomKeyframe], settings: CompositionRenderSettings) {
        let previous = self.settings
        let pointerChanged = settings.cursorEvents != previous.cursorEvents
            || settings.clickEvents != previous.clickEvents
        let keystrokesChanged = settings.keystrokes != previous.keystrokes
            || settings.exportStyle.keystrokes.filter != previous.exportStyle.keystrokes.filter

        self.settings = settings
        self.motionFX = settings.zoomPreset.motionFX
        interpolator = ZoomInterpolator(
            keyframes: keyframes,
            springEnabled: settings.exportStyle.springCameraEnabled,
            springSettings: settings.zoomPreset.motionFX.spring,
            base: SourceCrop.base(settings.sourceCrop)
        )
        rippleEvaluator = ClickRippleEvaluator(settings: settings.zoomPreset.motionFX)
        if pointerChanged || settings.exportStyle.cursorSmoothingEnabled != previous.exportStyle.cursorSmoothingEnabled {
            smoothedCursorEvents = Self.cursorPath(for: settings, smoother: cursorSmoother)
        }
        if pointerChanged {
            cursorActivity = CursorVisibility.activityTimes(cursor: settings.cursorEvents, clicks: settings.clickEvents)
        }
        if keystrokesChanged {
            keystrokePills = KeystrokeOverlayTimeline.pills(from: settings.keystrokes, filter: settings.exportStyle.keystrokes.filter)
        }
    }

    func cropRect(at time: TimeInterval) -> NormalizedRect {
        interpolator.cropRect(at: time)
    }

    /// - Parameter time: source seconds (everything the renderer draws is timed in the
    ///   recording's own time).
    func renderImage(
        source: CIImage,
        camera: CIImage? = nil,
        at time: TimeInterval,
        outputWidth: Int,
        outputHeight: Int
    ) -> CIImage {
        let sourceWidth = settings.sourceWidth
        let sourceHeight = settings.sourceHeight
        let canvas = CGSize(width: outputWidth, height: outputHeight)
        let outputRect = CGRect(origin: .zero, size: canvas)
        let unit = CanvasLayout.referenceUnit(for: canvas)
        let cropRect = interpolator.cropRect(at: time)

        // Hidden regions first, so the cursor and ripples stay visible on top of them.
        var decorated = compositeBlurRegions(onto: source, at: time)
        if settings.exportStyle.clickRipplesEnabled {
            decorated = compositeRipples(onto: decorated, at: time)
        }
        if settings.drawCursor, settings.exportStyle.showCursor {
            decorated = compositeCursor(onto: decorated, at: time)
        }

        let crop = CGRect(
            x: cropRect.x * sourceWidth,
            y: cropRect.y * sourceHeight,
            width: cropRect.width * sourceWidth,
            height: cropRect.height * sourceHeight
        )
        let cropped = decorated.cropped(to: crop)
        var fitted = fitContent(cropped, croppedExtent: cropped.extent, canvas: canvas)
        if settings.exportStyle.motionBlurEnabled {
            fitted = applyMotionBlur(to: fitted, at: time, cropRect: cropRect, unit: unit)
        }

        var finalImage: CIImage
        if let layers = backdropLayers(contentFrame: fitted.frame, canvas: canvas) {
            finalImage = fitted.image
                .applyingFilter("CIBlendWithMask", parameters: [kCIInputMaskImageKey: layers.contentMask])
                .composited(over: layers.background)
        } else {
            finalImage = fitted.image.composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: outputRect))
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
            finalImage = applySpotlight(to: finalImage, at: outputPoint, canvas: canvas)
        }

        // The bubble stays put and sharp while the screen content moves underneath it.
        var bubble: CGRect?
        if settings.camera.isVisible, let camera, let frame = cameraFrame(contentFrame: fitted.frame) {
            finalImage = compositeCamera(camera, onto: finalImage, in: frame)
            bubble = frame
        }

        finalImage = compositeTextOverlays(onto: finalImage, at: time, canvas: canvas, unit: unit)
        finalImage = compositeKeystrokes(onto: finalImage, at: time, contentFrame: fitted.frame, unit: unit)

        let watermark = settings.exportStyle.watermarkText.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.exportStyle.watermarkEnabled, !watermark.isEmpty {
            finalImage = compositeWatermark(watermark, onto: finalImage, canvas: canvas, avoiding: bubble)
        }

        return finalImage.cropped(to: outputRect)
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

        // An explicit colour space, so preview and export produce the same pixels.
        ciContext.render(
            finalImage,
            to: outputBuffer,
            bounds: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight),
            colorSpace: Self.colorSpace
        )
        return outputBuffer
    }

    // MARK: - Layout

    private struct FittedContent {
        let image: CIImage
        let frame: CGRect
    }

    private func fitContent(_ image: CIImage, croppedExtent: CGRect, canvas: CGSize) -> FittedContent {
        let padding = settings.exportStyle.backgroundEnabled
            ? CanvasLayout.padding(canvas: canvas, ratio: settings.exportStyle.paddingRatio)
            : 0
        let availableWidth = canvas.width - padding * 2
        let availableHeight = canvas.height - padding * 2
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

    // MARK: - Background

    /// The background, drop shadow, and rounded-corner mask only change with the layout
    /// and style, so they are rendered once into GPU-resident buffers and reused.
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
        let background: BackgroundStyle
        let imageURL: URL?

        init(canvas: CGSize, contentFrame: CGRect, cornerRadius: CGFloat, style: ExportStyle, imageURL: URL?) {
            func quantized(_ value: CGFloat) -> Int { Int((value * 100).rounded()) }
            outputWidth = Int(canvas.width)
            outputHeight = Int(canvas.height)
            frame = [contentFrame.minX, contentFrame.minY, contentFrame.width, contentFrame.height].map(quantized)
            self.cornerRadius = quantized(cornerRadius)
            shadowEnabled = style.shadowEnabled
            background = style.background
            self.imageURL = imageURL
        }
    }

    /// `nil` without a background: the recording fills the canvas edge to edge.
    private func backdropLayers(contentFrame: CGRect, canvas: CGSize) -> BackdropLayers? {
        let style = settings.exportStyle
        guard style.backgroundEnabled, contentFrame.width > 0, contentFrame.height > 0 else { return nil }

        // Sizes are designed at 1080p and scale with the canvas.
        let unit = CanvasLayout.referenceUnit(for: canvas)
        let cornerRadius = max(0, style.cornerRadius) * unit
        let key = BackdropKey(
            canvas: canvas,
            contentFrame: contentFrame,
            cornerRadius: cornerRadius,
            style: style,
            imageURL: settings.backgroundImageURL
        )
        if let cachedBackdrop, cachedBackdrop.key == key {
            return cachedBackdrop.layers
        }

        let outputRect = CGRect(origin: .zero, size: canvas)
        var background = makeBackground(style.background, in: outputRect)
        if style.shadowEnabled {
            // Core Image space is y-up, so a negative offset puts the shadow below.
            let shadowMask = roundedRectMask(
                rect: contentFrame.offsetBy(dx: 0, dy: -8 * unit),
                radius: cornerRadius,
                canvasSize: canvas
            )
            let shadow = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.32))
                .cropped(to: outputRect)
                .applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputMaskImageKey: shadowMask
                        .clampedToExtent()
                        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 20 * unit])
                        .cropped(to: outputRect)
                ])
            background = shadow.composited(over: background)
        }

        let contentMask = roundedRectMask(rect: contentFrame, radius: cornerRadius, canvasSize: canvas)
        let layers = BackdropLayers(
            background: materialize(background, size: canvas),
            contentMask: materialize(contentMask, size: canvas)
        )
        cachedBackdrop = (key, layers)
        return layers
    }

    private func makeBackground(_ style: BackgroundStyle, in rect: CGRect) -> CIImage {
        switch style.kind {
        case .solid:
            return CIImage(color: ciColor(style.solidColor)).cropped(to: rect)
        case .gradient:
            return linearGradient(from: style.gradientStart, to: style.gradientEnd, angle: style.gradientAngle, in: rect)
        case .image:
            if let image = backgroundImage(filling: rect, blur: style.imageBlur) {
                return image
            }
            return wallpaper(.midnight, in: rect)
        case .wallpaper:
            return wallpaper(style.wallpaper, in: rect)
        case .none:
            return CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: rect)
        }
    }

    /// A diagonal gradient with a soft glow in the top-left corner.
    private func wallpaper(_ preset: WallpaperPreset, in rect: CGRect) -> CIImage {
        let colors = preset.colors
        let base = linearGradient(from: colors.start, to: colors.end, angle: 135, in: rect)
        guard let filter = CIFilter(name: "CIRadialGradient") else { return base }
        let transparent = RGBAColor(red: colors.glow.red, green: colors.glow.green, blue: colors.glow.blue, alpha: 0)
        filter.setValue(CIVector(x: rect.minX + rect.width * 0.18, y: rect.maxY - rect.height * 0.1), forKey: "inputCenter")
        filter.setValue(0, forKey: "inputRadius0")
        filter.setValue(max(rect.width, rect.height) * 0.75, forKey: "inputRadius1")
        filter.setValue(ciColor(colors.glow), forKey: "inputColor0")
        filter.setValue(ciColor(transparent), forKey: "inputColor1")
        let glow = (filter.outputImage ?? CIImage.empty()).cropped(to: rect)
        return glow.composited(over: base).cropped(to: rect)
    }

    private func linearGradient(from start: RGBAColor, to end: RGBAColor, angle: Double, in rect: CGRect) -> CIImage {
        guard let filter = CIFilter(name: "CILinearGradient") else {
            return CIImage(color: ciColor(start)).cropped(to: rect)
        }
        let points = BackgroundStyle.gradientEndpoints(angle: angle, in: rect)
        filter.setValue(CIVector(x: points.start.x, y: points.start.y), forKey: "inputPoint0")
        filter.setValue(CIVector(x: points.end.x, y: points.end.y), forKey: "inputPoint1")
        filter.setValue(ciColor(start), forKey: "inputColor0")
        filter.setValue(ciColor(end), forKey: "inputColor1")
        return (filter.outputImage ?? CIImage.empty()).cropped(to: rect)
    }

    /// The project's background picture, scaled to fill `rect` (cropping the overflow)
    /// and optionally blurred; `nil` when it can't be read.
    private func backgroundImage(filling rect: CGRect, blur: Double) -> CIImage? {
        guard let url = settings.backgroundImageURL else { return nil }
        let loaded: CIImage?
        if let cachedBackgroundImage, cachedBackgroundImage.url == url {
            loaded = cachedBackgroundImage.image
        } else {
            loaded = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
            cachedBackgroundImage = (url, loaded)
        }
        guard let image = loaded, image.extent.width > 0, image.extent.height > 0,
              image.extent.width.isFinite, image.extent.height.isFinite
        else { return nil }

        let extent = image.extent
        let scale = max(rect.width / extent.width, rect.height / extent.height)
        var filled = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scale,
                kCIInputAspectRatioKey: 1
            ])
        filled = filled.transformed(by: CGAffineTransform(
            translationX: rect.midX - filled.extent.width / 2 - filled.extent.minX,
            y: rect.midY - filled.extent.height / 2 - filled.extent.minY
        ))
        let softness = min(max(blur, 0), 1)
        if softness > 0 {
            filled = filled.clampedToExtent()
                .applyingGaussianBlur(sigma: softness * 0.04 * Double(min(rect.width, rect.height)))
        }
        return filled.cropped(to: rect)
    }

    /// Anti-aliased white rounded rectangle on transparent. `rect` is in Core Image space
    /// (bottom-left origin), which matches an unflipped bitmap context.
    private func roundedRectMask(rect: CGRect, radius: CGFloat, canvasSize: CGSize) -> CIImage {
        renderBitmap(size: canvasSize) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.addPath(Self.roundedPath(rect, radius: radius))
            context.fillPath()
        }
    }

    private static func roundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let corner = min(max(0, radius), rect.width / 2, rect.height / 2)
        return CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    }

    // MARK: - Motion blur

    /// Smears the picture along the camera's movement over the last frame, like a camera
    /// shutter would, so fast zooms and pans read as motion instead of judder.
    private func applyMotionBlur(to content: FittedContent, at time: TimeInterval, cropRect: NormalizedRect, unit: CGFloat) -> FittedContent {
        let frame = content.frame
        guard frame.width > 0, frame.height > 0 else { return content }
        let previous = interpolator.cropRect(at: max(0, time - 1.0 / 60.0))
        let motion = CameraMotion.between(previous, cropRect, contentSize: frame.size)

        // A shutter open for half the frame: blur over half the distance moved.
        let panLength = hypot(motion.pan.dx, motion.pan.dy) * 0.5
        let zoomLength = abs(motion.zoom) * max(frame.width, frame.height) * 0.25
        let limit = 36 * unit
        guard max(panLength, zoomLength) > 0.75 else { return content }

        let clamped = content.image.clampedToExtent()
        let blurred: CIImage
        if zoomLength >= panLength {
            let anchor = motion.zoomAnchor ?? CGPoint(x: 0.5, y: 0.5)
            blurred = clamped.applyingFilter("CIZoomBlur", parameters: [
                kCIInputCenterKey: CIVector(x: frame.minX + anchor.x * frame.width, y: frame.minY + anchor.y * frame.height),
                "inputAmount": min(zoomLength, limit)
            ])
        } else {
            blurred = clamped.applyingFilter("CIMotionBlur", parameters: [
                kCIInputRadiusKey: min(panLength, limit),
                kCIInputAngleKey: atan2(motion.pan.dy, motion.pan.dx)
            ])
        }
        return FittedContent(image: blurred.cropped(to: frame), frame: frame)
    }

    // MARK: - Blur regions

    /// Blurs or pixelates the regions active at `time`, in source pixels, so they follow
    /// the content through zooms.
    private func compositeBlurRegions(onto image: CIImage, at time: TimeInterval) -> CIImage {
        let active = settings.blurRegions.filter { $0.isActive(at: time) }
        guard !active.isEmpty else { return image }

        let extent = image.extent
        // Strengths are designed for a 1080-pixel-tall source.
        let unit = max(min(extent.width, extent.height) / 1080, 0.25)
        let clamped = image.clampedToExtent()
        return active.reduce(image) { composed, region in
            let rect = CGRect(
                x: extent.minX + region.rect.minX * extent.width,
                y: extent.minY + region.rect.minY * extent.height,
                width: region.rect.width * extent.width,
                height: region.rect.height * extent.height
            ).intersection(extent)
            guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return composed }

            let strength = CGFloat(min(max(region.strength, 0), 1))
            let hidden: CIImage
            switch region.kind {
            case .blur:
                hidden = clamped.applyingGaussianBlur(sigma: Double((6 + 30 * strength) * unit))
            case .pixelate:
                hidden = clamped.applyingFilter("CIPixellate", parameters: [
                    kCIInputCenterKey: CIVector(x: rect.minX, y: rect.minY),
                    kCIInputScaleKey: max(4, (10 + 40 * strength) * unit)
                ])
            }
            return hidden.cropped(to: rect).composited(over: composed)
        }
    }

    // MARK: - Watermark

    private func compositeWatermark(_ text: String, onto image: CIImage, canvas: CGSize, avoiding bubble: CGRect?) -> CIImage {
        let unit = CanvasLayout.referenceUnit(for: canvas)
        let key = "\(text)@\(Int((unit * 100).rounded()))"
        let textImage: CIImage
        if let cachedWatermark, cachedWatermark.key == key {
            textImage = cachedWatermark.image
        } else {
            textImage = makeWatermarkImage(text: text, fontSize: 18 * unit)
            cachedWatermark = (key, textImage)
        }

        // Bottom-right corner, 24 px (at 1080p) in from each edge, unless the camera
        // bubble is there.
        let origin = OverlayLayout.watermarkOrigin(
            size: textImage.extent.size,
            canvas: canvas,
            margin: 24 * unit,
            avoiding: bubble
        )
        return textImage
            .transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
            .composited(over: image)
    }

    /// Just the text, in a bitmap the size of the text.
    private func makeWatermarkImage(text: String, fontSize: CGFloat) -> CIImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(6, fontSize), weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.55)
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        return renderBitmap(size: CGSize(width: size.width + 2, height: size.height + 2)) { _ in
            (text as NSString).draw(at: CGPoint(x: 1, y: 1), withAttributes: attributes)
        }
    }

    // MARK: - Text overlays

    private func compositeTextOverlays(onto image: CIImage, at time: TimeInterval, canvas: CGSize, unit: CGFloat) -> CIImage {
        var result = image
        for overlay in settings.textOverlays {
            let opacity = overlay.opacity(at: time)
            guard opacity > 0.001 else { continue }
            let text = overlay.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let plate = textPlate(text: text, style: overlay.style, scale: overlay.scale, unit: unit, maxWidth: canvas.width * 0.86)
            let frame = OverlayLayout.centeredFrame(
                size: plate.extent.size,
                normalizedCenter: overlay.center,
                canvas: canvas,
                margin: 16 * unit
            )
            var placed = plate.transformed(by: CGAffineTransform(translationX: frame.minX, y: frame.minY))
            if opacity < 1 {
                placed = fade(placed, opacity: opacity)
            }
            result = placed.composited(over: result)
        }
        return result
    }

    private func textPlate(text: String, style: TextOverlay.Style, scale: Double, unit: CGFloat, maxWidth: CGFloat) -> CIImage {
        let key = "\(style.rawValue)|\(Int(scale * 100))|\(Int(unit * 1000))|\(Int(maxWidth))|\(text)"
        if let cached = textCache[key] {
            return cached
        }
        if textCache.count > 48 {
            textCache.removeAll()
        }

        let layout = TextPlateLayout.layout(text: text, style: style, scale: scale, unit: unit, maxWidth: maxWidth)
        let size = layout.size
        let fontSize = layout.fontSize
        let plate = renderBitmap(size: size) { context in
            let plateRect = CGRect(origin: .zero, size: size)
            switch style {
            case .title:
                break
            case .caption:
                context.setFillColor(CGColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 0.78))
                context.addPath(Self.roundedPath(plateRect, radius: fontSize * 0.45))
                context.fillPath()
            case .callout:
                let accent = Self.accent
                context.setFillColor(CGColor(
                    srgbRed: CGFloat(accent.red),
                    green: CGFloat(accent.green),
                    blue: CGFloat(accent.blue),
                    alpha: 1
                ))
                context.addPath(Self.roundedPath(plateRect, radius: min(size.height / 2, fontSize * 0.9)))
                context.fillPath()
            }
            layout.string.draw(in: CGRect(
                x: layout.padding.width,
                y: layout.padding.height,
                width: layout.textSize.width,
                height: layout.textSize.height
            ))
        }
        textCache[key] = plate
        return plate
    }

    // MARK: - Keystrokes

    private func compositeKeystrokes(onto image: CIImage, at time: TimeInterval, contentFrame: CGRect, unit: CGFloat) -> CIImage {
        let style = settings.exportStyle.keystrokes
        guard style.filter != .off, !keystrokePills.isEmpty, contentFrame.width > 0,
              let current = KeystrokeOverlayTimeline.pill(at: time, in: keystrokePills)
        else { return image }

        let scale = CGFloat(min(max(style.scale, 0.5), 2))
        let pill = keystrokePill(current.pill.text, fontSize: 30 * unit * scale, unit: unit)
        let origin = OverlayLayout.keystrokeOrigin(
            size: pill.extent.size,
            contentFrame: contentFrame,
            placement: style.placement,
            margin: 28 * unit
        )
        var placed = pill.transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
        if current.opacity < 1 {
            placed = fade(placed, opacity: current.opacity)
        }
        return placed.composited(over: image)
    }

    private func keystrokePill(_ text: String, fontSize: CGFloat, unit: CGFloat) -> CIImage {
        let key = "\(Int(fontSize * 100))|\(text)"
        if let cached = pillCache[key] {
            return cached
        }
        if pillCache.count > 64 {
            pillCache.removeAll()
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(6, fontSize), weight: .semibold),
            .foregroundColor: NSColor.white,
            .kern: fontSize * 0.02
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let padding = CGSize(width: fontSize * 0.75, height: fontSize * 0.42)
        let size = CGSize(
            width: (textSize.width + padding.width * 2).rounded(.up),
            height: (textSize.height + padding.height * 2).rounded(.up)
        )
        let border = max(1, 1.5 * unit)
        let pill = renderBitmap(size: size) { context in
            let rect = CGRect(origin: .zero, size: size)
            let path = Self.roundedPath(rect.insetBy(dx: border / 2, dy: border / 2), radius: fontSize * 0.55)
            context.setFillColor(CGColor(srgbRed: 0.06, green: 0.06, blue: 0.08, alpha: 0.82))
            context.addPath(path)
            context.fillPath()
            context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16))
            context.setLineWidth(border)
            context.addPath(path)
            context.strokePath()
            (text as NSString).draw(
                at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2),
                withAttributes: attributes
            )
        }
        pillCache[key] = pill
        return pill
    }

    // MARK: - Camera

    private func cameraFrame(contentFrame: CGRect) -> CGRect? {
        guard contentFrame.width > 0, contentFrame.height > 0 else { return nil }
        let frame = CameraBubbleLayout.frame(
            in: contentFrame.size,
            position: settings.camera.position,
            diameterFraction: settings.camera.diameterFraction
        )
        guard frame.width >= 2 else { return nil }
        return frame.offsetBy(dx: contentFrame.minX, dy: contentFrame.minY)
    }

    private struct CameraKey: Equatable {
        /// Hundredths of a pixel.
        let diameter: Int
        let shape: CameraShape
        let border: Bool
    }

    /// The camera's shape, border, and shadow, relative to the bubble's bottom-left
    /// corner; they change only with its size and style.
    private struct CameraLayers {
        /// White where the face shows.
        let mask: CIImage
        /// Border and shadow, drawn under the face.
        let backing: CIImage
    }

    private func cameraLayers(diameter: CGFloat) -> CameraLayers {
        let camera = settings.camera
        let key = CameraKey(diameter: Int((diameter * 100).rounded()), shape: camera.shape, border: camera.borderEnabled)
        if let cachedCamera, cachedCamera.key == key {
            return cachedCamera.layers
        }

        func cornerRadius(for side: CGFloat, inset: CGFloat) -> CGFloat {
            switch camera.shape {
            case .circle: return side / 2
            case .roundedSquare: return diameter * 0.22 + inset
            }
        }

        let rimWidth = camera.borderEnabled ? max(2, diameter * 0.022) : 0
        let outerSide = diameter + rimWidth * 2
        let mask = shapeImage(side: diameter, cornerRadius: cornerRadius(for: diameter, inset: 0), color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        let outline = shapeImage(side: outerSide, cornerRadius: cornerRadius(for: outerSide, inset: rimWidth), color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92))
            .transformed(by: CGAffineTransform(translationX: -rimWidth, y: -rimWidth))
        let shadowShape = shapeImage(side: outerSide, cornerRadius: cornerRadius(for: outerSide, inset: rimWidth), color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35))
        let shadowOffset = max(2, diameter * 0.025)
        let shadow = shadowShape
            .transformed(by: CGAffineTransform(translationX: -rimWidth, y: -rimWidth - shadowOffset))
            .applyingGaussianBlur(sigma: Double(max(3, diameter * 0.045)))

        let margin = diameter * 0.25 + rimWidth
        let bounds = CGRect(x: -margin, y: -margin, width: diameter + margin * 2, height: diameter + margin * 2)
        let backing = camera.borderEnabled ? outline.composited(over: shadow) : shadow
        let layers = CameraLayers(mask: mask, backing: backing.cropped(to: bounds))
        cachedCamera = (key, layers)
        return layers
    }

    private func compositeCamera(_ camera: CIImage, onto image: CIImage, in bubble: CGRect) -> CIImage {
        let extent = camera.extent
        guard extent.width > 0, extent.height > 0 else { return image }

        let layers = cameraLayers(diameter: bubble.width)
        let toBubble = CGAffineTransform(translationX: bubble.minX, y: bubble.minY)

        // Aspect-fill the camera frame into the bubble's square.
        let scale = max(bubble.width / extent.width, bubble.height / extent.height)
        let placed = camera
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(
                translationX: bubble.midX - extent.width * scale / 2,
                y: bubble.midY - extent.height * scale / 2
            ))
            .cropped(to: bubble)

        let face = placed.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputMaskImageKey: layers.mask.transformed(by: toBubble)
        ])
        return face
            .composited(over: layers.backing.transformed(by: toBubble))
            .composited(over: image)
    }

    private func shapeImage(side: CGFloat, cornerRadius: CGFloat, color: CGColor) -> CIImage {
        renderBitmap(size: CGSize(width: side, height: side)) { context in
            context.setFillColor(color)
            context.addPath(Self.roundedPath(CGRect(x: 0, y: 0, width: side, height: side), radius: cornerRadius))
            context.fillPath()
        }
    }

    // MARK: - Cursor

    /// A cursor image with its hot spot. Rasterized once and only moved and scaled per
    /// frame.
    private struct CursorSprite {
        let image: CIImage
        /// Hot spot in `image` coordinates (y up).
        let hotSpot: CGPoint
        /// Sprite pixels per cursor point.
        let density: CGFloat
    }

    private func cursorLocation(at time: TimeInterval) -> CGPoint? {
        cursorSmoother.location(at: time, in: smoothedCursorEvents)
    }

    private func compositeCursor(onto image: CIImage, at time: TimeInterval) -> CIImage {
        guard let cursorLocation = cursorLocation(at: time) else {
            return image
        }
        let opacity = CursorVisibility.opacity(
            at: time,
            activity: cursorActivity,
            hideWhenIdle: settings.exportStyle.hideIdleCursor
        )
        guard opacity > 0.001 else { return image }

        let clickScale: CGFloat
        if settings.exportStyle.cursorScaleOnClickEnabled {
            clickScale = CursorClickScale.scale(at: time, clicks: settings.clickEvents, settings: motionFX)
        } else {
            clickScale = 1
        }
        let sizeRange = ExportStyle.cursorSizeRange
        let size = CGFloat(min(max(settings.exportStyle.cursorSize, sizeRange.lowerBound), sizeRange.upperBound))
        let sprite = cursorSprite(for: CursorKindTimeline.kind(at: time, in: settings.cursorKinds))

        // Sprite pixels -> source pixels (the real cursor's size, times the size setting
        // and the click bounce), then the hot spot placed on the cursor.
        let scale = max(settings.sourcePixelsPerPoint, 1) * size * clickScale / sprite.density
        guard scale > 0, scale.isFinite else { return image }
        let scaled = sprite.image.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: scale,
            kCIInputAspectRatioKey: 1
        ])
        var placed = scaled.transformed(by: CGAffineTransform(
            translationX: cursorLocation.x - sprite.hotSpot.x * scale,
            y: cursorLocation.y - sprite.hotSpot.y * scale
        ))
        if opacity < 1 {
            placed = fade(placed, opacity: opacity)
        }
        return placed.composited(over: image)
    }

    /// The system's own cursor image for `kind`, or a drawn arrow if those aren't loaded.
    private func cursorSprite(for kind: CursorKind) -> CursorSprite {
        if let sprite = systemCursors[kind] {
            return sprite
        }
        if let system = SystemCursorImages.shared.sprite(for: kind) {
            let image = CIImage(cgImage: system.image)
            let sprite = CursorSprite(
                image: image,
                hotSpot: CGPoint(x: system.hotSpot.x, y: image.extent.height - system.hotSpot.y),
                density: system.density
            )
            systemCursors[kind] = sprite
            return sprite
        }
        if let fallbackCursor {
            return fallbackCursor
        }
        let sprite = makeArrowSprite(density: SystemCursorImages.density)
        fallbackCursor = sprite
        return sprite
    }

    private func makeArrowSprite(density: CGFloat) -> CursorSprite {
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
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35))
            context.addPath(shadow)
            context.fillPath()

            let path = CGMutablePath()
            appendCursorPath(path, at: .zero)
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.85))
            context.setLineWidth(1.2)
            context.addPath(path)
            context.drawPath(using: .fillStroke)
        }

        // The tip sits `margin` points from the top-left; Core Image is y-up.
        let tip = CGPoint(x: margin * density, y: pixelSize.height - margin * density)
        return CursorSprite(image: image, hotSpot: tip, density: density)
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

    private func applySpotlight(to image: CIImage, at point: CGPoint, canvas: CGSize) -> CIImage {
        let outputRect = CGRect(origin: .zero, size: canvas)
        guard let filter = CIFilter(name: "CIRadialGradient") else { return image }
        filter.setValue(CIVector(x: point.x, y: point.y), forKey: "inputCenter")
        let unit = CanvasLayout.referenceUnit(for: canvas)
        filter.setValue(motionFX.spotlightInnerRadius * unit, forKey: "inputRadius0")
        filter.setValue(motionFX.spotlightOuterRadius * unit, forKey: "inputRadius1")
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

    /// Multiplies `image`'s alpha by `opacity`.
    private func fade(_ image: CIImage, opacity: Double) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(min(max(opacity, 0), 1)))
        ])
    }

    private func ciColor(_ color: RGBAColor) -> CIColor {
        CIColor(
            red: CGFloat(color.red),
            green: CGFloat(color.green),
            blue: CGFloat(color.blue),
            alpha: CGFloat(color.alpha),
            colorSpace: Self.colorSpace
        ) ?? CIColor(red: CGFloat(color.red), green: CGFloat(color.green), blue: CGFloat(color.blue), alpha: CGFloat(color.alpha))
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
        ciContext.render(image.cropped(to: bounds), to: buffer, bounds: bounds, colorSpace: Self.colorSpace)
        return CIImage(cvPixelBuffer: buffer, options: [.colorSpace: Self.colorSpace])
    }

    /// Draws into a transparent sRGB bitmap with a bottom-left origin (Core Image space).
    /// AppKit drawing (strings, NSImage) works inside `draw`: an `NSGraphicsContext` is
    /// installed around it, since the render queues don't have one.
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
                  space: Self.colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            return CIImage.empty()
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        draw(context)
        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = context.makeImage() else {
            return CIImage.empty()
        }
        return CIImage(cgImage: cgImage)
    }
}
