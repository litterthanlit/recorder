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
    let zoomPreset: ZoomPreset
    let cursorEvents: [CursorEvent]
    let clickEvents: [ClickEvent]
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
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first

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

        let timeRange = CMTimeRange(
            start: CMTime(seconds: trimStart, preferredTimescale: 600),
            duration: CMTime(seconds: exportDuration, preferredTimescale: 600)
        )

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = timeRange

        let readerOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

        var audioReaderOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                audioReaderOutput = output
            }
        }

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

        var audioWriterInput: AVAssetWriterInput?
        if audioReaderOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioWriterInput = input
            }
        }

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        guard reader.startReading() else {
            throw reader.error ?? VideoExporterError.readerFailed
        }

        let renderSize = naturalSize.applying(preferredTransform)
        let sourceWidth = abs(renderSize.width)
        let sourceHeight = abs(renderSize.height)

        let compositor = CompositionRenderer(
            keyframes: configuration.keyframes,
            settings: CompositionRenderSettings(
                exportStyle: configuration.exportStyle,
                zoomPreset: configuration.zoomPreset,
                cursorEvents: configuration.cursorEvents,
                clickEvents: configuration.clickEvents,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                drawCursor: configuration.drawCursor
            )
        )

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

            if let audioReaderOutput, let audioWriterInput {
                while audioWriterInput.isReadyForMoreMediaData,
                      let audioSample = audioReaderOutput.copyNextSampleBuffer() {
                    try appendShiftedAudio(
                        audioSample,
                        to: audioWriterInput,
                        trimStartTime: trimStartTime,
                        writer: writer
                    )
                }
            }

            let progress = exportDuration > 0
                ? min(1, (seconds - trimStart) / exportDuration)
                : 1
            progressHandler(progress)
        }

        if let audioReaderOutput, let audioWriterInput {
            while audioWriterInput.isReadyForMoreMediaData,
                  let audioSample = audioReaderOutput.copyNextSampleBuffer() {
                try appendShiftedAudio(
                    audioSample,
                    to: audioWriterInput,
                    trimStartTime: trimStartTime,
                    writer: writer
                )
            }
            audioWriterInput.markAsFinished()
        }

        writerInput.markAsFinished()

        if reader.status == .failed {
            throw reader.error ?? VideoExporterError.readerFailed
        }

        try await finishWriting(writer)
        progressHandler(1)
    }

    private func appendShiftedAudio(
        _ audioSample: CMSampleBuffer,
        to audioWriterInput: AVAssetWriterInput,
        trimStartTime: CMTime,
        writer: AVAssetWriter
    ) throws {
        let audioPTS = CMSampleBufferGetPresentationTimeStamp(audioSample)
        let relativeAudioPTS = CMTimeMaximum(
            .zero,
            CMTimeSubtract(audioPTS, trimStartTime)
        )
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(audioSample),
            presentationTimeStamp: relativeAudioPTS,
            decodeTimeStamp: .invalid
        )
        var shifted: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: audioSample,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &shifted
        )
        if let shifted, !audioWriterInput.append(shifted) {
            throw writer.error ?? VideoExporterError.writerSetupFailed
        }
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
