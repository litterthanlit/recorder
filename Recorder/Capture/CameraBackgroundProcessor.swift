import CoreImage
import CoreVideo
import Foundation
import Vision

/// Applies Zoom-style virtual backgrounds to camera frames via Vision person segmentation.
final class CameraBackgroundProcessor {
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let segmentationRequest: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()

    func process(_ pixelBuffer: CVPixelBuffer, mode: CameraBackgroundMode) -> CVPixelBuffer? {
        guard mode != .none else { return pixelBuffer }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([segmentationRequest])
        } catch {
            return pixelBuffer
        }

        guard let maskBuffer = segmentationRequest.results?.first?.pixelBuffer else {
            return pixelBuffer
        }

        let original = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = original.extent
        let mask = softenedMask(scaleMask(CIImage(cvPixelBuffer: maskBuffer), to: extent), extent: extent)
        let background = makeBackground(mode: mode, original: original, extent: extent)

        let blended = original.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: background,
            kCIInputMaskImageKey: mask
        ]).cropped(to: extent)

        var output: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            CVPixelBufferGetWidth(pixelBuffer),
            CVPixelBufferGetHeight(pixelBuffer),
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ] as CFDictionary,
            &output
        )
        guard status == kCVReturnSuccess, let output else { return nil }
        ciContext.render(blended, to: output)
        return output
    }

    func makeCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        return ciContext.createCGImage(image, from: image.extent)
    }

    private func scaleMask(_ mask: CIImage, to extent: CGRect) -> CIImage {
        let scaleX = extent.width / max(mask.extent.width, 1)
        let scaleY = extent.height / max(mask.extent.height, 1)
        return mask
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .cropped(to: extent)
    }

    private func softenedMask(_ mask: CIImage, extent: CGRect) -> CIImage {
        mask
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.2])
            .cropped(to: extent)
    }

    private func makeBackground(
        mode: CameraBackgroundMode,
        original: CIImage,
        extent: CGRect
    ) -> CIImage {
        switch mode {
        case .none:
            return original
        case .white:
            return CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
                .cropped(to: extent)
        case .studio:
            return CIImage(color: CIColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1))
                .cropped(to: extent)
        case .blur:
            return original
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 26])
                .cropped(to: extent)
        case .gradient:
            return makeGradient(extent: extent)
        }
    }

    private func makeGradient(extent: CGRect) -> CIImage {
        let filter = CIFilter(name: "CILinearGradient")
        filter?.setValue(CIVector(x: extent.midX, y: extent.minY), forKey: "inputPoint0")
        filter?.setValue(
            CIColor(red: 0.42, green: 0.62, blue: 0.92, alpha: 1),
            forKey: "inputColor0"
        )
        filter?.setValue(CIVector(x: extent.midX, y: extent.maxY), forKey: "inputPoint1")
        filter?.setValue(
            CIColor(red: 0.96, green: 0.94, blue: 0.91, alpha: 1),
            forKey: "inputColor1"
        )
        return (filter?.outputImage ?? CIImage(color: .white)).cropped(to: extent)
    }
}
