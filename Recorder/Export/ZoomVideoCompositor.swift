import CoreImage
import CoreVideo
import Foundation

struct ZoomVideoCompositor {
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let interpolator: ZoomInterpolator

    init(keyframes: [ZoomKeyframe]) {
        interpolator = ZoomInterpolator(keyframes: keyframes)
    }

    func cropRect(at time: TimeInterval) -> NormalizedRect {
        interpolator.cropRect(at: time)
    }

    func renderFrame(
        pixelBuffer: CVPixelBuffer,
        at time: TimeInterval,
        sourceWidth: CGFloat,
        sourceHeight: CGFloat,
        outputWidth: Int,
        outputHeight: Int
    ) throws -> CVPixelBuffer {
        let cropRect = interpolator.cropRect(at: time)

        let inputImage = CIImage(cvPixelBuffer: pixelBuffer)
        let cropX = cropRect.x * sourceWidth
        let cropY = cropRect.y * sourceHeight
        let cropW = cropRect.width * sourceWidth
        let cropH = cropRect.height * sourceHeight

        let cropped = inputImage.cropped(to: CGRect(x: cropX, y: cropY, width: cropW, height: cropH))
        let croppedExtent = cropped.extent

        let scaleX = CGFloat(outputWidth) / croppedExtent.width
        let scaleY = CGFloat(outputHeight) / croppedExtent.height
        let scaled = cropped.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

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

        ciContext.render(scaled, to: outputBuffer)
        return outputBuffer
    }
}
