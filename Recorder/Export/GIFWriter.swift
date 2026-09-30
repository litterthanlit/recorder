import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

/// Writes an export's frames as a looping GIF with ImageIO.
enum GIFWriter {
    static func write(
        frames: ExportFrameSource,
        to url: URL,
        frameRate: Int,
        progress: @escaping (Double) -> Void
    ) async throws {
        let count = frames.frameCount
        guard count > 0,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, count, nil)
        else {
            throw VideoExporterError.writerSetupFailed
        }
        let fileProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)

        let delays = GIFTiming.delays(frameCount: count, fps: frameRate)
        var lastReported = -1.0
        for index in 0..<count {
            try Task.checkCancellation()
            let buffer = try frames.renderFrame(index, pool: nil)
            guard let image = compactImage(from: buffer) else {
                throw VideoExporterError.bufferCreationFailed
            }
            let delay = Double(delays[index]) / 100
            let frameProperties: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay
                ]
            ]
            CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary)

            let fraction = Double(index + 1) / Double(count)
            if fraction - lastReported >= 0.01 || index == count - 1 {
                lastReported = fraction
                // Writing the file at the end takes a moment too.
                progress(fraction * 0.95)
            }
            await Task.yield()
        }

        guard CGImageDestinationFinalize(destination) else {
            throw VideoExporterError.writerSetupFailed
        }
        progress(1)
    }

    /// The frame as a 16-bit image: ImageIO keeps every frame until the GIF is written,
    /// and a GIF has at most 256 colours anyway, so this halves memory for no visible loss.
    private static func compactImage(from buffer: CVPixelBuffer) -> CGImage? {
        var full: CGImage?
        VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &full)
        guard let full else { return nil }
        let width = full.width
        let height = full.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 5,
            bytesPerRow: width * 2,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        ) else {
            return full
        }
        context.draw(full, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? full
    }
}
