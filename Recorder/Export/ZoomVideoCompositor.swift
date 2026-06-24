import AppKit
import CoreImage
import CoreVideo
import Foundation

struct CompositorSettings {
    let exportStyle: ExportStyle
    let cursorEvents: [CursorEvent]
    let sourceWidth: CGFloat
    let sourceHeight: CGFloat
    let drawCursor: Bool
}

struct ZoomVideoCompositor {
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let interpolator: ZoomInterpolator
    private let settings: CompositorSettings
    private let cursorSmoother = CursorPathSmoother()
    private let smoothedCursorEvents: [CursorEvent]

    init(keyframes: [ZoomKeyframe], settings: CompositorSettings) {
        interpolator = ZoomInterpolator(keyframes: keyframes)
        self.settings = settings
        smoothedCursorEvents = settings.exportStyle.cursorSmoothingEnabled
            ? cursorSmoother.smooth(settings.cursorEvents)
            : settings.cursorEvents
    }

    func cropRect(at time: TimeInterval) -> NormalizedRect {
        interpolator.cropRect(at: time)
    }

    func renderFrame(
        pixelBuffer: CVPixelBuffer,
        at time: TimeInterval,
        outputWidth: Int,
        outputHeight: Int
    ) throws -> CVPixelBuffer {
        let sourceWidth = settings.sourceWidth
        let sourceHeight = settings.sourceHeight
        let cropRect = interpolator.cropRect(at: time)

        let inputImage = CIImage(cvPixelBuffer: pixelBuffer)
        let cropX = cropRect.x * sourceWidth
        let cropY = cropRect.y * sourceHeight
        let cropW = cropRect.width * sourceWidth
        let cropH = cropRect.height * sourceHeight

        let cropped = inputImage.cropped(to: CGRect(x: cropX, y: cropY, width: cropW, height: cropH))
        let croppedExtent = cropped.extent

        var contentImage = cropped
        if settings.drawCursor,
           settings.exportStyle.cursorSmoothingEnabled,
           let cursorLocation = cursorSmoother.location(at: time, in: smoothedCursorEvents) {
            contentImage = compositeCursor(
                onto: contentImage,
                cursorLocation: cursorLocation,
                cropRect: cropRect,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight
            )
        }

        let fitted = fitContent(
            contentImage,
            croppedExtent: croppedExtent,
            outputWidth: outputWidth,
            outputHeight: outputHeight
        )

        let finalImage: CIImage
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
        composed = maskedContent.composited(over: composed)

        if settings.exportStyle.watermarkEnabled {
            composed = drawWatermark(on: composed, outputRect: outputRect)
        }

        return composed.cropped(to: outputRect)
    }

    private func makeBackground(in rect: CGRect) -> CIImage {
        guard let filter = CIFilter(name: "CILinearGradient") else {
            return CIImage(color: CIColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1)).cropped(to: rect)
        }
        filter.setValue(CIVector(cgRect: CGRect(x: rect.midX, y: rect.maxY, width: 1, height: 1)), forKey: "inputPoint0")
        filter.setValue(CIVector(cgRect: CGRect(x: rect.midX, y: rect.minY, width: 1, height: 1)), forKey: "inputPoint1")
        filter.setValue(CIColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1), forKey: "inputColor0")
        filter.setValue(CIColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1), forKey: "inputColor1")
        return (filter.outputImage ?? CIImage.empty()).cropped(to: rect)
    }

    private func roundedRectMask(rect: CGRect, radius: CGFloat, canvasSize: CGSize) -> CIImage {
        let width = Int(canvasSize.width)
        let height = Int(canvasSize.height)
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

    private func compositeCursor(
        onto image: CIImage,
        cursorLocation: CGPoint,
        cropRect: NormalizedRect,
        sourceWidth: CGFloat,
        sourceHeight: CGFloat
    ) -> CIImage {
        let localX = (cursorLocation.x / sourceWidth - cropRect.x) / cropRect.width
        let localY = (cursorLocation.y / sourceHeight - cropRect.y) / cropRect.height
        guard localX >= 0, localX <= 1, localY >= 0, localY <= 1 else {
            return image
        }

        let extent = image.extent
        let x = extent.minX + localX * extent.width
        let y = extent.maxY - localY * extent.height
        let cursorRect = CGRect(x: x - 2, y: y - 2, width: 18, height: 18)

        let cursorImage = renderBitmap(size: extent.size) { context in
            context.translateBy(x: 0, y: extent.height)
            context.scaleBy(x: 1, y: -1)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: cursorRect.minX, y: cursorRect.minY))
            path.addLine(to: CGPoint(x: cursorRect.minX, y: cursorRect.minY + 14))
            path.addLine(to: CGPoint(x: cursorRect.minX + 4, y: cursorRect.minY + 10))
            path.addLine(to: CGPoint(x: cursorRect.minX + 8, y: cursorRect.minY + 16))
            path.addLine(to: CGPoint(x: cursorRect.minX + 10, y: cursorRect.minY + 15))
            path.addLine(to: CGPoint(x: cursorRect.minX + 6, y: cursorRect.minY + 9))
            path.addLine(to: CGPoint(x: cursorRect.minX + 11, y: cursorRect.minY + 9))
            path.closeSubpath()
            context.setFillColor(NSColor.white.cgColor)
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.85).cgColor)
            context.setLineWidth(1.2)
            context.addPath(path)
            context.drawPath(using: .fillStroke)
        }

        return cursorImage.composited(over: image)
    }

    private func renderBitmap(size: CGSize, draw: (CGContext) -> Void) -> CIImage {
        let width = Int(size.width)
        let height = Int(size.height)
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
