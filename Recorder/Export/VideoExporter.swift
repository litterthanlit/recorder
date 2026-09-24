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
    /// Output frame rate. The export runs on this fixed clock regardless of how often
    /// the (variable frame rate) source recording changed.
    let frameRate: Int
    /// Separately recorded camera track, if any, and how to show it.
    let cameraURL: URL?
    let camera: CameraOverlayStyle
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
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoExpectedSourceFrameRateKey: max(1, configuration.frameRate),
                    AVVideoMaxKeyFrameIntervalKey: max(1, configuration.frameRate) * 2
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
                drawCursor: configuration.drawCursor,
                camera: configuration.camera
            )
        )

        var cameraFrames: CameraFrameSource?
        if configuration.camera.isVisible {
            cameraFrames = try await CameraFrameSource(url: configuration.cameraURL)
        }

        let trimStartTime = CMTime(seconds: trimStart, preferredTimescale: 600)
        var lastVideoTime = CMTime.zero

        // Each input must be marked finished as soon as its source runs dry. AVAssetWriter
        // interleaves inputs and will otherwise hold one back forever waiting for the other.
        var audioFinished = audioReaderOutput == nil || audioWriterInput == nil
        func pumpAudio() throws {
            guard !audioFinished, let audioReaderOutput, let audioWriterInput else { return }
            while audioWriterInput.isReadyForMoreMediaData {
                guard let audioSample = audioReaderOutput.copyNextSampleBuffer() else {
                    audioWriterInput.markAsFinished()
                    audioFinished = true
                    return
                }
                try appendShiftedAudio(
                    audioSample,
                    to: audioWriterInput,
                    trimStartTime: trimStartTime,
                    writer: writer
                )
            }
        }

        let timeline = ConstantFrameRateTimeline(
            frameRate: configuration.frameRate,
            duration: exportDuration,
            sourceStart: trimStart
        )
        let outputTimescale = CMTimeScale(timeline.frameRate)

        func readNextSourceFrame() -> (buffer: CVPixelBuffer, time: TimeInterval)? {
            while let sample = readerOutput.copyNextSampleBuffer() {
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                return (buffer, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)))
            }
            return nil
        }

        // Hold the most recent source frame at or before each output time; `pending` is
        // the next source frame, read ahead to know when to switch.
        var heldFrame: (buffer: CVPixelBuffer, time: TimeInterval)?
        var pendingFrame = readNextSourceFrame()
        var frameIndex = 0

        while frameIndex < timeline.frameCount {
            try Task.checkCancellation()
            try pumpAudio()

            guard writerInput.isReadyForMoreMediaData else {
                try await Task.sleep(nanoseconds: 2_000_000)
                continue
            }

            let sourceTime = timeline.sourceTime(forFrame: frameIndex)
            // Before the first source frame, show it anyway rather than a blank frame.
            while let pending = pendingFrame,
                  heldFrame == nil
                    || ConstantFrameRateTimeline.shouldAdvance(to: pending.time, forSourceTime: sourceTime) {
                heldFrame = pending
                pendingFrame = readNextSourceFrame()
            }
            guard let currentFrame = heldFrame else {
                throw reader.error ?? VideoExporterError.missingVideoTrack
            }

            let processed = try compositor.renderFrame(
                pixelBuffer: currentFrame.buffer,
                cameraBuffer: cameraFrames?.frame(atSourceTime: sourceTime),
                at: sourceTime,
                outputWidth: outputWidth,
                outputHeight: outputHeight,
                pool: adaptor.pixelBufferPool
            )

            let presentationTime = CMTime(value: CMTimeValue(frameIndex), timescale: outputTimescale)
            if !adaptor.append(processed, withPresentationTime: presentationTime) {
                throw writer.error ?? VideoExporterError.writerSetupFailed
            }
            lastVideoTime = presentationTime
            frameIndex += 1
            progressHandler(Double(frameIndex) / Double(max(timeline.frameCount, 1)))
        }

        writerInput.markAsFinished()

        // Anything left in the trimmed range is past the last output frame. Drain it so
        // the reader can keep feeding the audio output.
        while pendingFrame != nil {
            pendingFrame = readNextSourceFrame()
        }

        while !audioFinished {
            try Task.checkCancellation()
            try pumpAudio()
            if !audioFinished {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
        }

        if reader.status == .failed {
            throw reader.error ?? VideoExporterError.readerFailed
        }

        // Keep a static tail: without this the file ends at the last source frame,
        // which can be well before the trim end when the screen stopped changing.
        writer.endSession(atSourceTime: CMTimeMaximum(
            lastVideoTime,
            CMTime(seconds: exportDuration, preferredTimescale: 600)
        ))

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

/// Sequential reader for the camera track that returns, for increasing source times, the
/// most recent camera frame at or before that time (or the first frame before it starts).
/// Camera time t lines up with screen time t (see `CameraTrackWriter`).
private final class CameraFrameSource {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var held: (buffer: CVPixelBuffer, time: TimeInterval)?
    private var pending: (buffer: CVPixelBuffer, time: TimeInterval)?

    /// Returns `nil` when there is no readable camera track.
    init?(url: URL?) async throws {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }

        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        pending = readNext()
    }

    func frame(atSourceTime time: TimeInterval) -> CVPixelBuffer? {
        while let next = pending,
              held == nil || ConstantFrameRateTimeline.shouldAdvance(to: next.time, forSourceTime: time) {
            held = next
            pending = readNext()
        }
        return held?.buffer
    }

    private func readNext() -> (buffer: CVPixelBuffer, time: TimeInterval)? {
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            return (buffer, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)))
        }
        return nil
    }
}
