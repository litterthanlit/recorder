import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

struct ExportConfiguration {
    let keyframes: [ZoomKeyframe]
    let outputSize: CGSize
    /// The edit: which parts of the recording play, in order, at what speed.
    let timeline: EditTimeline
    /// What to draw (look, cursor, overlays). Its source size is replaced with the
    /// recording's actual size.
    let render: CompositionRenderSettings
    /// Output frame rate. The export runs on this fixed clock regardless of how often
    /// the (variable frame rate) source recording changed.
    let frameRate: Int
    let options: ExportOptions
    /// Separately recorded camera track, if any.
    let cameraURL: URL?
    /// What each audio track holds, and their levels.
    let audioTrackRoles: [AudioTrackRole]
    let audio: AudioMixSettings

    var bitrate: Int {
        options.bitrate(size: outputSize, fps: frameRate)
    }
}

/// Writes an export: composited frames from `ExportFrameSource` into a movie (H.264 or
/// HEVC MP4, ProRes MOV) with the mixed audio, or into a GIF.
///
/// Cancelling the task stops it at the next frame; the partly written file is left for
/// the caller to delete.
final class VideoExporter {
    func export(
        sourceURL: URL,
        outputURL: URL,
        configuration: ExportConfiguration,
        progressHandler: @escaping (Double) -> Void
    ) async throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        let frames = try await ExportFrameSource(sourceURL: sourceURL, configuration: configuration)
        defer { frames.cancel() }

        switch configuration.options.format {
        case .gif:
            try await GIFWriter.write(frames: frames, to: outputURL, frameRate: configuration.frameRate, progress: progressHandler)
        case .mp4, .hevc, .prores:
            try await writeMovie(
                frames: frames,
                sourceURL: sourceURL,
                outputURL: outputURL,
                configuration: configuration,
                progressHandler: progressHandler
            )
        }
    }

    private func writeMovie(
        frames: ExportFrameSource,
        sourceURL: URL,
        outputURL: URL,
        configuration: ExportConfiguration,
        progressHandler: @escaping (Double) -> Void
    ) async throws {
        let format = configuration.options.format
        let asset = AVURLAsset(url: sourceURL)
        // Mic narration and system audio are separate tracks.
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        // Audio is read from a composition of the edit, which cuts it, time-stretches the
        // sped-up parts (keeping pitch) and mixes mic and system audio at their levels.
        var audioReader: AVAssetReader?
        var audioReaderOutput: AVAssetReaderOutput?
        if !audioTracks.isEmpty {
            let built = try await TimelineCompositionBuilder.build(
                asset: asset,
                timeline: frames.edit,
                includeVideo: false,
                audioRoles: configuration.audioTrackRoles,
                audio: configuration.audio
            )
            if !built.audioTracks.isEmpty {
                let compositionReader = try AVAssetReader(asset: built.composition)
                let output = AVAssetReaderAudioMixOutput(audioTracks: built.audioTracks, audioSettings: Self.mixedPCMSettings)
                output.audioMix = built.audioMix
                output.audioTimePitchAlgorithm = .spectral
                output.alwaysCopiesSampleData = false
                if compositionReader.canAdd(output) {
                    compositionReader.add(output)
                    audioReader = compositionReader
                    audioReaderOutput = output
                }
            }
        }

        let outputWidth = frames.outputWidth
        let outputHeight = frames.outputHeight
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: format == .prores ? .mov : .mp4)
        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: Self.videoSettings(
                format: format,
                width: outputWidth,
                height: outputHeight,
                bitrate: configuration.bitrate,
                frameRate: configuration.frameRate
            )
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
            // ProRes movies carry uncompressed audio, like the editors they're made for.
            let settings = format == .prores ? Self.mixedPCMSettings : Self.mixedAACSettings
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioWriterInput = input
            }
        }

        guard writer.startWriting() else {
            throw writer.error ?? VideoExporterError.writerSetupFailed
        }
        writer.startSession(atSourceTime: .zero)
        if let audioReader, !audioReader.startReading() {
            writer.cancelWriting()
            throw audioReader.error ?? VideoExporterError.readerFailed
        }

        do {
            // Each input must be marked finished as soon as its source runs dry.
            // AVAssetWriter interleaves inputs and will otherwise hold one back forever
            // waiting for the other.
            var audioFinished = audioReaderOutput == nil || audioWriterInput == nil
            func pumpAudio() throws {
                guard !audioFinished, let audioReaderOutput, let audioWriterInput else { return }
                while audioWriterInput.isReadyForMoreMediaData {
                    guard let audioSample = audioReaderOutput.copyNextSampleBuffer() else {
                        audioWriterInput.markAsFinished()
                        audioFinished = true
                        return
                    }
                    // The composition is already on the output timeline.
                    if !audioWriterInput.append(audioSample) {
                        throw writer.error ?? VideoExporterError.writerSetupFailed
                    }
                }
            }

            let outputTimescale = CMTimeScale(frames.frameRate)
            var lastVideoTime = CMTime.zero
            var frameIndex = 0
            var lastReportedProgress = -1.0
            let frameCount = frames.frameCount

            while frameIndex < frameCount {
                try Task.checkCancellation()
                try pumpAudio()

                guard writerInput.isReadyForMoreMediaData else {
                    try await Task.sleep(nanoseconds: 2_000_000)
                    continue
                }

                let processed = try frames.renderFrame(frameIndex, pool: adaptor.pixelBufferPool)
                let presentationTime = CMTime(value: CMTimeValue(frameIndex), timescale: outputTimescale)
                if !adaptor.append(processed, withPresentationTime: presentationTime) {
                    throw writer.error ?? VideoExporterError.writerSetupFailed
                }
                lastVideoTime = presentationTime
                frameIndex += 1

                // Report whole percents at most, not every frame.
                let progress = Double(frameIndex) / Double(max(frameCount, 1))
                if progress - lastReportedProgress >= 0.01 || frameIndex == frameCount {
                    lastReportedProgress = progress
                    progressHandler(progress)
                }
            }

            writerInput.markAsFinished()
            frames.cancel()

            while !audioFinished {
                try Task.checkCancellation()
                try pumpAudio()
                if !audioFinished {
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
            }

            if let audioReader, audioReader.status == .failed {
                throw audioReader.error ?? VideoExporterError.readerFailed
            }

            // Keep a static tail: without this the file ends at the last source frame,
            // which can be well before the end when the screen stopped changing.
            writer.endSession(atSourceTime: CMTimeMaximum(
                lastVideoTime,
                CMTime(seconds: frames.edit.outputDuration, preferredTimescale: 600)
            ))

            try await finishWriting(writer)
            progressHandler(1)
        } catch {
            audioReader?.cancelReading()
            if writer.status == .writing {
                writer.cancelWriting()
            }
            throw error
        }
    }

    /// Video settings for `format`, tagged Rec. 709 so players show the colours the
    /// preview does.
    static func videoSettings(format: ExportFormat, width: Int, height: Int, bitrate: Int, frameRate: Int) -> [String: Any] {
        let color: [String: Any] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ]
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: max(1, frameRate),
            AVVideoMaxKeyFrameIntervalKey: max(1, frameRate) * 2
        ]
        var settings: [String: Any]
        switch format {
        case .prores:
            settings = [
                AVVideoCodecKey: AVVideoCodecType.proRes422,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ]
        case .hevc:
            settings = VideoCodecChoice.hevc.outputSettings(width: width, height: height, compression: compression)
        case .mp4, .gif:
            settings = VideoCodecChoice.forFrame(width: width, height: height)
                .outputSettings(width: width, height: height, compression: compression)
        }
        settings[AVVideoColorPropertiesKey] = color
        return settings
    }

    private static let mixedPCMSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false
    ]

    private static let mixedAACSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 192_000
    ]

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

/// The export's frames, composited, on a fixed output clock over the edit.
///
/// The recording is read once, in order: segments are never reordered, so each output
/// frame's source time is at or after the previous one's. Each output frame shows the
/// latest source frame at or before its source time (ScreenCaptureKit only delivers
/// frames when the screen changes).
final class ExportFrameSource {
    let edit: EditTimeline
    let outputWidth: Int
    let outputHeight: Int
    let frameRate: Int

    private let clock: ConstantFrameRateTimeline
    private let reader: AVAssetReader
    private let readerOutput: AVAssetReaderTrackOutput
    private let compositor: CompositionRenderer
    private var cameraFrames: CameraFrameSource?
    private var heldFrame: (buffer: CVPixelBuffer, time: TimeInterval)?
    private var pendingFrame: (buffer: CVPixelBuffer, time: TimeInterval)?

    var frameCount: Int {
        clock.frameCount
    }

    init(sourceURL: URL, configuration: ExportConfiguration) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoExporterError.missingVideoTrack
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let assetDuration = try await asset.load(.duration)

        let edit = configuration.timeline.normalized(sourceDuration: CMTimeGetSeconds(assetDuration))
        self.edit = edit
        outputWidth = Int(configuration.outputSize.width)
        outputHeight = Int(configuration.outputSize.height)
        frameRate = max(1, configuration.frameRate)
        clock = ConstantFrameRateTimeline(frameRate: max(1, configuration.frameRate), duration: edit.outputDuration)

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: edit.trimStart, preferredTimescale: 600),
            end: CMTime(seconds: edit.trimEnd, preferredTimescale: 600)
        )
        let output = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        output.alwaysCopiesSampleData = false
        reader.add(output)
        self.reader = reader
        readerOutput = output

        let renderSize = naturalSize.applying(preferredTransform)
        var renderSettings = configuration.render
        renderSettings.sourceWidth = abs(renderSize.width)
        renderSettings.sourceHeight = abs(renderSize.height)
        // Frames are timed by this edit, so transitions land on its cuts.
        renderSettings.timeline = edit
        compositor = CompositionRenderer(keyframes: configuration.keyframes, settings: renderSettings)

        if renderSettings.camera.isVisible {
            cameraFrames = try await CameraFrameSource(url: configuration.cameraURL)
        }

        guard reader.startReading() else {
            throw reader.error ?? VideoExporterError.readerFailed
        }
        pendingFrame = readNextSourceFrame()
    }

    /// Renders output frame `index`. Call with increasing indexes.
    /// - Parameter pool: output buffers come from it when given (a writer's pool).
    func renderFrame(_ index: Int, pool: CVPixelBufferPool?) throws -> CVPixelBuffer {
        let outputTime = clock.outputTime(forFrame: index)
        let sourceTime = edit.sourceTime(forOutput: outputTime)
        // Before the first source frame, show it anyway rather than a blank frame.
        while let pending = pendingFrame,
              heldFrame == nil || ConstantFrameRateTimeline.shouldAdvance(to: pending.time, forSourceTime: sourceTime) {
            heldFrame = pending
            pendingFrame = readNextSourceFrame()
        }
        guard let current = heldFrame else {
            throw reader.error ?? VideoExporterError.missingVideoTrack
        }
        return try compositor.renderFrame(
            pixelBuffer: current.buffer,
            cameraBuffer: cameraFrames?.frame(atSourceTime: sourceTime),
            at: sourceTime,
            outputTime: outputTime,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            pool: pool
        )
    }

    /// Stops reading the recording (safe to call more than once).
    func cancel() {
        if reader.status == .reading {
            reader.cancelReading()
        }
        cameraFrames?.cancel()
        heldFrame = nil
        pendingFrame = nil
    }

    private func readNextSourceFrame() -> (buffer: CVPixelBuffer, time: TimeInterval)? {
        while let sample = readerOutput.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            return (buffer, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)))
        }
        return nil
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

    func cancel() {
        if reader.status == .reading {
            reader.cancelReading()
        }
    }

    private func readNext() -> (buffer: CVPixelBuffer, time: TimeInterval)? {
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            return (buffer, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)))
        }
        return nil
    }
}

extension VideoCodecChoice {
    /// `AVAssetWriterInput` video settings; adds the profile for H.264 (the H.264 profile
    /// constant is invalid for HEVC, which uses its default Main profile).
    func outputSettings(width: Int, height: Int, compression: [String: Any]) -> [String: Any] {
        var compression = compression
        let codecType: AVVideoCodecType
        switch self {
        case .h264:
            codecType = .h264
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        case .hevc:
            codecType = .hevc
        }
        return [
            AVVideoCodecKey: codecType,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression
        ]
    }
}
