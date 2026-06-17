import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

final class VideoExporter {
    func export(
        sourceURL: URL,
        outputURL: URL,
        keyframes: [ZoomKeyframe],
        outputSize: CGSize,
        progressHandler: @escaping (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoExporterError.missingVideoTrack
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let duration = try await asset.load(.duration)

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let outputWidth = Int(outputSize.width)
        let outputHeight = Int(outputSize.height)
        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: outputWidth,
                AVVideoHeightKey: outputHeight,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: outputWidth * outputHeight * 4,
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

        let compositor = ZoomVideoCompositor(keyframes: keyframes)
        let renderSize = naturalSize.applying(preferredTransform)
        let sourceWidth = abs(renderSize.width)
        let sourceHeight = abs(renderSize.height)
        let totalSeconds = max(CMTimeGetSeconds(duration), 0.001)

        var frameIndex = 0

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

            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let seconds = CMTimeGetSeconds(presentationTime)

            let processed = try compositor.renderFrame(
                pixelBuffer: pixelBuffer,
                at: seconds,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                outputWidth: outputWidth,
                outputHeight: outputHeight
            )

            if !adaptor.append(processed, withPresentationTime: presentationTime) {
                throw writer.error ?? VideoExporterError.writerSetupFailed
            }

            frameIndex += 1
            let progress = min(1, seconds / totalSeconds)
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
