import AppKit
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// One moment of a take to show, on both clocks (`output` is nil where the edit cut it).
struct AgentFrameMoment: Equatable {
    let source: TimeInterval
    let output: TimeInterval?
}

/// Draws frames of a take for agents, as JPEG images: the raw recording, or composited
/// by the export's own renderer, one by one or tiled into a labelled contact sheet.
enum AgentFrameRenderer {
    struct Request {
        let videoURL: URL
        let cameraURL: URL?
        let moments: [AgentFrameMoment]
        let rendered: Bool
        let keyframes: [ZoomKeyframe]
        let renderSettings: CompositionRenderSettings
        /// The export's canvas size (rendered frames keep its shape).
        let canvasSize: CGSize
        let sourceSize: CGSize
        let asSheet: Bool
        /// A 0–1 coordinate grid over raw frames.
        let grid: Bool
        /// The clock the labels show.
        let labelTimeBase: AgentTimeBase
    }

    /// Longest side of a single frame.
    static let frameLongEdge: CGFloat = 1280

    /// JPEG data for each frame, or for the one sheet.
    static func render(_ request: Request, progress: MCPProgress) async throws -> [Data] {
        try await Task.detached(priority: .userInitiated) {
            try await AgentFrameRenderer.renderImages(request, progress: progress)
        }.value
    }

    private static func renderImages(_ request: Request, progress: MCPProgress) async throws -> [Data] {
        let shape = request.rendered ? request.canvasSize : request.sourceSize
        let aspect = shape.height > 0 ? shape.width / shape.height : 16.0 / 9.0
        let layout = FrameSampling.sheetLayout(count: request.moments.count, tileAspect: aspect)
        let frameSize = request.asSheet
            ? layout.tileSize
            : FrameSampling.fitted(shape, longEdge: frameLongEdge)

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: request.videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // Rendering composites full-size frames, like the export; raw frames can be small.
        generator.maximumSize = request.rendered ? CGSize.zero : frameSize

        var cameraGenerator: AVAssetImageGenerator?
        if request.rendered, let cameraURL = request.cameraURL {
            let camera = AVAssetImageGenerator(asset: AVURLAsset(url: cameraURL))
            camera.appliesPreferredTrackTransform = true
            camera.maximumSize = CGSize(width: 640, height: 640)
            cameraGenerator = camera
        }

        let context = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
        var renderer: CompositionRenderer?
        var images: [CGImage] = []
        for (index, moment) in request.moments.enumerated() {
            try Task.checkCancellation()
            let time = CMTime(seconds: moment.source, preferredTimescale: 6000)
            let frame = try await generator.image(at: time).image

            if request.rendered {
                if renderer == nil {
                    var settings = request.renderSettings
                    settings.sourceWidth = CGFloat(frame.width)
                    settings.sourceHeight = CGFloat(frame.height)
                    renderer = CompositionRenderer(keyframes: request.keyframes, settings: settings, ciContext: context)
                }
                var camera: CIImage?
                if let cameraGenerator, let cameraFrame = try? await cameraGenerator.image(at: time).image {
                    camera = CIImage(cgImage: cameraFrame)
                }
                let width = Int(frameSize.width)
                let height = Int(frameSize.height)
                guard let composited = renderer?.renderImage(
                    source: CIImage(cgImage: frame),
                    camera: camera,
                    at: moment.source,
                    outputTime: moment.output,
                    outputWidth: width,
                    outputHeight: height
                ), let image = context.createCGImage(
                    composited,
                    from: CGRect(x: 0, y: 0, width: width, height: height),
                    format: .RGBA8,
                    colorSpace: colorSpace
                ) else {
                    throw AgentToolError("Couldn't render the frame at \(Timecode.precise(moment.source)).")
                }
                images.append(image)
            } else {
                images.append(request.grid ? drawGrid(on: frame) : frame)
            }
            progress.report(0.05 + 0.85 * Double(index + 1) / Double(request.moments.count), "Frame \(index + 1) of \(request.moments.count)")
        }

        if request.asSheet {
            let labels = request.moments.enumerated().map { index, moment in
                label(index: index, moment: moment, timeBase: request.labelTimeBase)
            }
            guard let sheet = contactSheet(images, labels: labels, layout: layout),
                  let data = jpeg(sheet)
            else {
                throw AgentToolError("Couldn't draw the contact sheet.")
            }
            return [data]
        }
        return try images.map { image in
            guard let data = jpeg(image) else {
                throw AgentToolError("Couldn't encode a frame.")
            }
            return data
        }
    }

    // MARK: - Drawing

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// "3 · 0:05.1", plus "(cut)" when the edit leaves that moment out.
    static func label(index: Int, moment: AgentFrameMoment, timeBase: AgentTimeBase) -> String {
        let time: String
        switch timeBase {
        case .source:
            time = Timecode.precise(moment.source)
        case .output:
            time = Timecode.precise(moment.output ?? 0)
        }
        return "\(index + 1) · \(time)" + (moment.output == nil ? " (cut)" : "")
    }

    /// Tiles in a grid on a dark sheet, each labelled underneath.
    static func contactSheet(_ images: [CGImage], labels: [String], layout: FrameSampling.SheetLayout) -> CGImage? {
        let size = layout.size
        return drawBitmap(size: size) { context in
            context.setFillColor(CGColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.9)
            ]
            for (index, image) in images.enumerated() {
                // Layout frames are top-left origin; the bitmap is bottom-left.
                let tile = layout.tileFrame(index)
                let flipped = CGRect(x: tile.minX, y: size.height - tile.maxY, width: tile.width, height: tile.height)
                context.draw(image, in: aspectFit(CGSize(width: image.width, height: image.height), in: flipped))
                let text = index < labels.count ? labels[index] : "\(index + 1)"
                (text as NSString).draw(
                    at: CGPoint(x: flipped.minX + 2, y: flipped.minY - layout.labelHeight + 4),
                    withAttributes: attributes
                )
            }
        }
    }

    /// Lines every 0.1 with their values along the top (x) and the left (y), origin top-left.
    static func drawGrid(on image: CGImage) -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        let fontSize = max(10, min(size.width, size.height) / 40)
        return drawBitmap(size: size) { context in
            context.draw(image, in: CGRect(origin: .zero, size: size))
            context.setLineWidth(max(1, fontSize / 10))
            context.setStrokeColor(CGColor(srgbRed: 1, green: 0.2, blue: 0.6, alpha: 0.65))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: NSColor.white,
                .backgroundColor: NSColor.black.withAlphaComponent(0.55)
            ]
            for step in 1...9 {
                let fraction = CGFloat(step) / 10
                let x = size.width * fraction
                let y = size.height * (1 - fraction)
                context.move(to: CGPoint(x: x, y: 0))
                context.addLine(to: CGPoint(x: x, y: size.height))
                context.move(to: CGPoint(x: 0, y: y))
                context.addLine(to: CGPoint(x: size.width, y: y))
                context.strokePath()
                let value = String(format: "%.1f", fraction) as NSString
                value.draw(at: CGPoint(x: x + 3, y: size.height - fontSize * 1.5), withAttributes: attributes)
                value.draw(at: CGPoint(x: 3, y: y + 3), withAttributes: attributes)
            }
        } ?? image
    }

    static func aspectFit(_ content: CGSize, in rect: CGRect) -> CGRect {
        guard content.width > 0, content.height > 0 else { return rect }
        let scale = min(rect.width / content.width, rect.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// An sRGB bitmap with a bottom-left origin; AppKit text drawing works inside `draw`.
    private static func drawBitmap(size: CGSize, draw: (CGContext) -> Void) -> CGImage? {
        let width = Int(size.width.rounded(.up))
        let height = Int(size.height.rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        draw(context)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    static func jpeg(_ image: CGImage, quality: Double = FrameSampling.jpegQuality) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
