import AppKit
import CoreImage
import CoreVideo
import Foundation

struct CompositionRenderSettings {
    var exportStyle: ExportStyle
    var zoomPreset: ZoomPreset
    var cursorEvents: [CursorEvent]
    var clickEvents: [ClickEvent]
    var sourceWidth: CGFloat
    var sourceHeight: CGFloat
    var drawCursor: Bool
}

final class CompositionRenderer {
    private let ciContext: CIContext
    private var interpolator: ZoomInterpolator
    private var settings: CompositionRenderSettings
    private let cursorSmoother = CursorPathSmoother()
    private var smoothedCursorEvents: [CursorEvent]
    private var rippleEvaluator: ClickRippleEvaluator
    private var motionFX: MotionFXSettings

    init(keyframes: [ZoomKeyframe], settings: CompositionRenderSettings, ciContext: CIContext? = nil) {
        self.ciContext = ciContext ?? CIContext(options: [.useSoftwareRenderer: false])
        self.settings = settings
        self.motionFX = settings.zoomPreset.motionFX
        self.interpolator = ZoomInterpolator(
            keyframes: keyframes,
            springEnabled: settings.exportStyle.springCameraEnabled,
            springSettings: settings.zoomPreset.motionFX.spring
        )
        self.rippleEvaluator = ClickRippleEvaluator(settings: settings.zoomPreset.motionFX)
        self.smoothedCursorEvents = settings.exportStyle.cursorSmoothingEnabled
            ? cursorSmoother.smooth(settings.cursorEvents)
            : settings.cursorEvents
    }

    func update(keyframes: [ZoomKeyframe], settings: CompositionRenderSettings) {
        self.settings = settings
        self.motionFX = settings.zoomPreset.motionFX
        interpolator = ZoomInterpolator(
            keyframes: keyframes,
            springEnabled: settings.exportStyle.springCameraEnabled,
            springSettings: settings.zoomPreset.motionFX.spring
        )
        rippleEvaluator = ClickRippleEvaluator(settings: settings.zoomPreset.motionFX)
        smoothedCursorEvents = settings.exportStyle.cursorSmoothingEnabled
            ? cursorSmoother.smooth(settings.cursorEvents)
            : settings.cursorEvents
    }

    func cropRect(at time: TimeInterval) -> NormalizedRect {
        interpolator.cropRect(at: time)
    }

    func renderImage(
        source: CIImage,
        at time: TimeInterval,
        outputWidth: Int,
        outputHeight: Int
    ) -> CIImage {
        let sourceWidth = settings.sourceWidth
        let sourceHeight = settings.sourceHeight
        let cropRect = interpolator.cropRect(at: time)

        var decorated = source
        if settings.exportStyle.clickRipplesEnabled {
            decorated = compositeRipples(
                onto: decorated,
                at: time,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight
            )
        }

        if settings.drawCursor {
            decorated = compositeCursor(
                onto: decorated,
                at: time,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight
            )
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

        if settings.exportStyle.watermarkEnabled {
            let outputRect = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
            finalImage = drawWatermark(on: finalImage, outputRect: outputRect)
        }

        return finalImage.cropped(to: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
    }

    func renderFrame(
        pixelBuffer: CVPixelBuffer,
        at time: TimeInterval,
        outputWidth: Int,
        outputHeight: Int
    ) throws -> CVPixelBuffer {
        let inputImage = CIImage(cvPixelBuffer: pixelBuffer)
        let finalImage = renderImage(
            source: inputImage,
            at: time,
            outputWidth: outputWidth,
            outputHeight: outputHeight
        )

        var outputBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            outputWidth,
            outputHeight,
            kCVPixelFormatType_32BGRA,
            nil,
            &outputBuffer
        )

        guard status == kCVReturnSuccess, let outputBuffer else {
            throw VideoExporterError.bufferCreationFailed
        }

        ciContext.render(finalImage, to: outputBuffer)
        return outputBuffer
    }

    func createCGImage(_ image: CIImage, size: CGSize) -> CGImage? {
        ciContext.createCGImage(image, from: CGRect(origin: .zero, size: size))
    }

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

    private func compositeOnBackground(
        _ content: CIImage,
        contentFrame: CGRect,
        outputWidth: Int,
        outputHeight: Int
    ) -> CIImage {
        let outputRect = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        let background = makeBackground(in: outputRect)

        let mask = roundedRectMask(
            rect: contentFrame,
            radius: settings.exportStyle.cornerRadius,
            canvasSize: outputRect.size
        )

        var composed = background

        if settings.exportStyle.shadowEnabled {
            let shadowRect = contentFrame.offsetBy(dx: 0, dy: -6)
            let shadowMask = roundedRectMask(
                rect: shadowRect,
                radius: settings.exportStyle.cornerRadius,
                canvasSize: outputRect.size
            )
            let shadow = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.35))
                .cropped(to: outputRect)
                .applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputMaskImageKey: shadowMask.applyingFilter("CIGaussianBlur", parameters: [
                        kCIInputRadiusKey: 16
                    ])
                ])
            composed = shadow.composited(over: composed)
        }

        let maskedContent = content.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputMaskImageKey: mask
        ])
        return maskedContent.composited(over: composed)
    }

    private func makeBackground(in rect: CGRect) -> CIImage {
        guard let filter = CIFilter(name: "CILinearGradient") else {
            return CIImage(color: CIColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1)).cropped(to: rect)
        }
        filter.setValue(CIVector(x: rect.midX, y: rect.maxY), forKey: "inputPoint0")
        filter.setValue(CIVector(x: rect.midX, y: rect.minY), forKey: "inputPoint1")
        filter.setValue(CIColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1), forKey: "inputColor0")
        filter.setValue(CIColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1), forKey: "inputColor1")
        return (filter.outputImage ?? CIImage.empty()).cropped(to: rect)
    }

    private func roundedRectMask(rect: CGRect, radius: CGFloat, canvasSize: CGSize) -> CIImage {
        let width = max(Int(canvasSize.width), 1)
        let height = max(Int(canvasSize.height), 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return CIImage(color: .white).cropped(to: rect)
        }

        context.setFillColor(NSColor.white.cgColor)
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        context.addPath(path.cgPath)
        context.fillPath()

        guard let cgImage = context.makeImage() else {
            return CIImage(color: .white).cropped(to: rect)
        }
        return CIImage(cgImage: cgImage)
    }

    private func drawWatermark(on image: CIImage, outputRect: CGRect) -> CIImage {
        let text = settings.exportStyle.watermarkText
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.55)
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let textRect = CGRect(
            x: outputRect.maxX - size.width - 24,
            y: 24,
            width: size.width,
            height: size.height
        )
        let textImage = renderBitmap(size: outputRect.size) { context in
            context.translateBy(x: 0, y: outputRect.height)
            context.scaleBy(x: 1, y: -1)
            (text as NSString).draw(in: textRect, withAttributes: attributes)
        }
        return textImage.composited(over: image)
    }

    private func cursorLocation(at time: TimeInterval) -> CGPoint? {
        cursorSmoother.location(at: time, in: smoothedCursorEvents)
    }

    private func compositeCursor(
        onto image: CIImage,
        at time: TimeInterval,
        sourceWidth: CGFloat,
        sourceHeight: CGFloat
    ) -> CIImage {
        guard let cursorLocation = cursorLocation(at: time) else {
            return image
        }

        let scale: CGFloat
        if settings.exportStyle.cursorScaleOnClickEnabled {
            scale = CursorClickScale.scale(at: time, clicks: settings.clickEvents, settings: motionFX)
        } else {
            scale = 1
        }

        let canvas = CGSize(width: sourceWidth, height: sourceHeight)
        let cursorImage = renderBitmap(size: canvas) { context in
            context.translateBy(x: 0, y: sourceHeight)
            context.scaleBy(x: 1, y: -1)

            let tip = CGPoint(x: cursorLocation.x, y: cursorLocation.y)
            context.translateBy(x: tip.x, y: tip.y)
            context.scaleBy(x: scale, y: scale)

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

        return cursorImage.composited(over: image)
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

    private func compositeRipples(
        onto image: CIImage,
        at time: TimeInterval,
        sourceWidth: CGFloat,
        sourceHeight: CGFloat
    ) -> CIImage {
        let ripples = rippleEvaluator.ripples(at: time, clicks: settings.clickEvents)
        guard !ripples.isEmpty else { return image }

        let canvas = CGSize(width: sourceWidth, height: sourceHeight)
        let rippleImage = renderBitmap(size: canvas) { context in
            context.translateBy(x: 0, y: sourceHeight)
            context.scaleBy(x: 1, y: -1)

            for ripple in ripples {
                let radius = motionFX.rippleRadius * (0.18 + 0.82 * ripple.progress)
                let alpha = (1 - ripple.progress) * (ripple.ring == 0 ? 0.7 : 0.42)
                let lineWidth: CGFloat = ripple.ring == 0 ? 3.2 : 2.2
                context.setStrokeColor(NSColor.white.withAlphaComponent(alpha).cgColor)
                context.setLineWidth(lineWidth)
                context.strokeEllipse(in: CGRect(
                    x: ripple.location.x - radius,
                    y: ripple.location.y - radius,
                    width: radius * 2,
                    height: radius * 2
                ))
            }
        }

        return rippleImage.composited(over: image)
    }

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
            y: contentFrame.maxY - localY * contentFrame.height
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

typealias ZoomVideoCompositor = CompositionRenderer
typealias CompositorSettings = CompositionRenderSettings

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
