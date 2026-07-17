import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

struct ExportConfiguration {
    let keyframes: [ZoomKeyframe]
    let outputSize: CGSize
    let bitrate: Int
    let trimStart: TimeInterval
    let trimEnd: TimeInterval
    let exportStyle: ExportStyle
    let cursorEvents: [CursorEvent]
    let drawCursor: Bool
}

final class VideoExporter {
    func export(
        sourceURL: URL,
        outputURL: URL,
        configuration: ExportConfiguration,
        progressHandler: @escaping (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoExporterError.missingVideoTrack
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let assetDuration = try await asset.load(.duration)
        let fullDuration = CMTimeGetSeconds(assetDuration)

        let trimStart = max(0, min(configuration.trimStart, fullDuration))
        let trimEnd = max(trimStart, min(configuration.trimEnd, fullDuration))
        let exportDuration = trimEnd - trimStart

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: trimStart, preferredTimescale: 600),
            duration: CMTime(seconds: exportDuration, preferredTimescale: 600)
        )

        let readerOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

        let outputWidth = Int(configuration.outputSize.width)
        let outputHeight = Int(configuration.outputSize.height)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: outputWidth,
                AVVideoHeightKey: outputHeight,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: configuration.bitrate,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
        )
        writerInput.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outputWidth,
                kCVPixelBufferHeightKey as String: outputHeight
            ]
        )

        guard writer.canAdd(writerInput) else {
            throw VideoExporterError.writerSetupFailed
        }
        writer.add(writerInput)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        guard reader.startReading() else {
            throw reader.error ?? VideoExporterError.readerFailed
        }

        let renderSize = naturalSize.applying(preferredTransform)
        let sourceWidth = abs(renderSize.width)
        let sourceHeight = abs(renderSize.height)

        let compositor = ZoomVideoCompositor(
            keyframes: configuration.keyframes,
            settings: CompositorSettings(
                exportStyle: configuration.exportStyle,
                cursorEvents: configuration.cursorEvents,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                drawCursor: configuration.drawCursor
            )
        )

        // Prefer source PTS so export timing stays correct when sample duration is 0/invalid.
        let trimStartTime = CMTime(seconds: trimStart, preferredTimescale: 600)

        while reader.status == .reading {
            guard writerInput.isReadyForMoreMediaData else {
                try await Task.sleep(nanoseconds: 2_000_000)
                continue
            }

            guard let sampleBuffer = readerOutput.copyNextSampleBuffer(),
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            else {
                break
            }

            let sourceTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let seconds = CMTimeGetSeconds(sourceTime)
            let presentationTime = CMTimeMaximum(
                .zero,
                CMTimeSubtract(sourceTime, trimStartTime)
            )

            let processed = try compositor.renderFrame(
                pixelBuffer: pixelBuffer,
                at: seconds,
                outputWidth: outputWidth,
                outputHeight: outputHeight
            )

            if !adaptor.append(processed, withPresentationTime: presentationTime) {
                throw writer.error ?? VideoExporterError.writerSetupFailed
            }

            let progress = exportDuration > 0
                ? min(1, (seconds - trimStart) / exportDuration)
                : 1
            progressHandler(progress)
        }

        writerInput.markAsFinished()

        if reader.status == .failed {
            throw reader.error ?? VideoExporterError.readerFailed
        }

        try await finishWriting(writer)
        progressHandler(1)
    }

    private func finishWriting(_ writer: AVAssetWriter) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                if writer.status == .failed {
                    continuation.resume(throwing: writer.error ?? VideoExporterError.writerSetupFailed)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

enum VideoExporterError: LocalizedError {
    case missingVideoTrack
    case readerFailed
    case writerSetupFailed
    case bufferCreationFailed

    var errorDescription: String? {
        switch self {
        case .missingVideoTrack:
            return "The recording does not contain a video track."
        case .readerFailed:
            return "Failed to read the source recording."
        case .writerSetupFailed:
            return "Failed to set up the export writer."
        case .bufferCreationFailed:
            return "Failed to create an export frame buffer."
        }
    }
}
