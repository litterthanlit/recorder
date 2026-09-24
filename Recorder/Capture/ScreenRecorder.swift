import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

protocol ScreenRecorderDelegate: AnyObject {
    /// `hostTime` is the first frame's capture time on the host clock (the same clock as
    /// `CACurrentMediaTime()`); it is t = 0 of the recording.
    func screenRecorder(_ recorder: ScreenRecorder, didReceiveFirstFrameAt hostTime: CMTime)
    func screenRecorder(_ recorder: ScreenRecorder, didWriteFrameAt time: TimeInterval)
    func screenRecorder(_ recorder: ScreenRecorder, didFailWith error: Error)
}

struct ScreenRecorderOptions {
    var captureTarget: CaptureTargetKind = .display
    var windowID: UInt32?
    var showCursor: Bool = true
    var excludeWindowIDs: [UInt32] = []
    var enableMicrophone: Bool = false
}

final class ScreenRecorder: NSObject {
    weak var delegate: ScreenRecorderDelegate?

    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioWriterInput: AVAssetWriterInput?
    private var sessionStartTime: TimeInterval = 0
    private var firstSampleTime: CMTime?
    private var lastWrittenTime: CMTime = .zero
    private var outputURL: URL?
    private var isRecording = false
    private var didNotifyFirstFrame = false
    private var didReportFailure = false
    /// Last frame handed to the writer; re-appended at stop so a still ending isn't cut off.
    private var lastWrittenPixelBuffer: CVPixelBuffer?
    private let writerQueue = DispatchQueue(label: "com.recorder.writer")
    private var options = ScreenRecorderOptions()

    private(set) var captureWidth: Int = 0
    private(set) var captureHeight: Int = 0
    private(set) var fps: Int = 60
    private(set) var scaleFactor: CGFloat = 2
    private(set) var captureOrigin: CGPoint = .zero
    private(set) var captureSizePoints: CGSize = .zero
    private(set) var windowTitle: String?
    private(set) var appName: String?

    static func listCapturableWindows() async throws -> [CaptureWindowInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        return content.windows
            .filter { $0.isOnScreen && $0.frame.width > 120 && $0.frame.height > 120 }
            .map {
                CaptureWindowInfo(
                    windowID: $0.windowID,
                    title: $0.title ?? "",
                    appName: $0.owningApplication?.applicationName ?? "Unknown"
                )
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func startRecording(to url: URL, options: ScreenRecorderOptions = ScreenRecorderOptions()) async throws {
        guard !isRecording else {
            throw ScreenRecorderError.alreadyRecording
        }
        self.options = options

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        let filter: SCContentFilter
        let displayScale: CGFloat
        let excludedWindows = content.windows.filter { options.excludeWindowIDs.contains($0.windowID) }

        switch options.captureTarget {
        case .display:
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                throw ScreenRecorderError.noDisplayAvailable
            }
            filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
            // NSScreen.main is the screen with the key window, not necessarily this display.
            let screen = NSScreen.screens.first { $0.displayIdentifier == display.displayID }
            displayScale = screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            windowTitle = nil
            appName = nil
            configureCaptureGeometry(display: display, displayScale: displayScale)

        case .window:
            guard let windowID = options.windowID,
                  let window = content.windows.first(where: { $0.windowID == windowID })
            else {
                throw ScreenRecorderError.windowNotAvailable
            }
            let windowCenter = CGPoint(x: window.frame.midX, y: window.frame.midY)
            let screen = Self.screen(containingGlobalPoint: windowCenter) ?? NSScreen.main
            // A display filter that includes one window still captures the whole display,
            // squeezed into the window-sized output. This filter captures just the window,
            // wherever it is, even when covered by other windows.
            filter = SCContentFilter(desktopIndependentWindow: window)
            displayScale = screen?.backingScaleFactor ?? 2
            windowTitle = window.title
            appName = window.owningApplication?.applicationName
            configureWindowGeometry(window: window, displayScale: displayScale)
        }

        scaleFactor = displayScale
        fps = 60

        let configuration = SCStreamConfiguration()
        configuration.width = captureWidth
        configuration.height = captureHeight
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        configuration.showsCursor = options.showCursor
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 6

        try setupWriter(
            outputURL: url,
            width: captureWidth,
            height: captureHeight,
            includeAudio: options.enableMicrophone
        )

        firstSampleTime = nil
        lastWrittenTime = .zero
        lastWrittenPixelBuffer = nil
        didNotifyFirstFrame = false
        didReportFailure = false
        outputURL = url

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: writerQueue)
            try await stream.startCapture()
        } catch {
            assetWriter?.cancelWriting()
            assetWriter = nil
            throw error
        }

        self.stream = stream
        sessionStartTime = CACurrentMediaTime()
        isRecording = true
    }

    /// - Parameter hostTime: the buffer's capture time on the host clock.
    func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer, hostTime: CMTime) {
        writerQueue.async { [weak self] in
            self?.writeAudioSampleBuffer(sampleBuffer, hostTime: hostTime)
        }
    }

    /// Stops capture and finalizes the movie. Safe to call after a stream error: the
    /// writer is always finished so whatever was recorded stays playable.
    func stopRecording() async throws -> RecordingResult {
        guard isRecording else {
            throw ScreenRecorderError.notRecording
        }

        let stopHostTime = CMClockGetTime(CMClockGetHostTimeClock())
        isRecording = false

        if let stream {
            // The stream may already have stopped on its own (window closed, error, user
            // stopped sharing). Finishing the file matters more than this call succeeding.
            try? await stream.stopCapture()
        }
        stream = nil

        return try await withCheckedThrowingContinuation { continuation in
            writerQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: ScreenRecorderError.notRecording)
                    return
                }

                let outputURL = self.outputURL

                guard let writer = self.assetWriter,
                      writer.status == .writing,
                      let firstSampleTime = self.firstSampleTime
                else {
                    let failedWriter = self.assetWriter
                    failedWriter?.cancelWriting()
                    self.assetWriter = nil
                    continuation.resume(throwing: failedWriter?.error ?? ScreenRecorderError.noFramesCaptured)
                    return
                }

                // ScreenCaptureKit only delivers frames when the screen changes, so a still
                // ending has no frames. Repeat the last frame at the stop time to keep it.
                let stopTime = CMTimeSubtract(stopHostTime, firstSampleTime)
                if stopTime > self.lastWrittenTime,
                   let lastBuffer = self.lastWrittenPixelBuffer,
                   let writerInput = self.writerInput,
                   writerInput.isReadyForMoreMediaData,
                   self.pixelBufferAdaptor?.append(lastBuffer, withPresentationTime: stopTime) == true {
                    self.lastWrittenTime = stopTime
                }

                self.writerInput?.markAsFinished()
                self.audioWriterInput?.markAsFinished()
                writer.endSession(atSourceTime: self.lastWrittenTime)
                self.lastWrittenPixelBuffer = nil

                writer.finishWriting {
                    if writer.status == .failed {
                        continuation.resume(throwing: writer.error ?? ScreenRecorderError.writerFailed)
                        return
                    }

                    guard let outputURL else {
                        continuation.resume(throwing: ScreenRecorderError.writerFailed)
                        return
                    }

                    let duration = CMTimeGetSeconds(self.lastWrittenTime)
                    continuation.resume(
                        returning: RecordingResult(
                            videoURL: outputURL,
                            duration: duration,
                            width: self.captureWidth,
                            height: self.captureHeight,
                            fps: self.fps,
                            scaleFactor: self.scaleFactor,
                            captureOrigin: self.captureOrigin,
                            captureSize: self.captureSizePoints,
                            windowTitle: self.windowTitle,
                            appName: self.appName
                        )
                    )
                }
            }
        }
    }

    private func configureCaptureGeometry(display: SCDisplay, displayScale: CGFloat) {
        // Global display space (top-left origin), the same space as CGEvent.location.
        // NSScreen.frame is bottom-left based and only matches for the main display.
        let bounds = CGDisplayBounds(display.displayID)
        captureOrigin = bounds.origin
        captureSizePoints = CGSize(width: display.width, height: display.height)
        (captureWidth, captureHeight) = CaptureGeometry.pixelSize(points: captureSizePoints, scale: displayScale)
    }

    /// The screen containing a point in global display space (top-left origin, as
    /// `SCWindow.frame` uses), not the bottom-left based space `NSScreen.frame` uses.
    private static func screen(containingGlobalPoint point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { CGDisplayBounds($0.displayIdentifier).contains(point) }
    }

    private func configureWindowGeometry(window: SCWindow, displayScale: CGFloat) {
        let frame = window.frame
        captureOrigin = frame.origin
        captureSizePoints = frame.size
        (captureWidth, captureHeight) = CaptureGeometry.pixelSize(points: frame.size, scale: displayScale)
    }

    private func setupWriter(outputURL: URL, width: Int, height: Int, includeAudio: Bool) throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: width * height * 4,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw ScreenRecorderError.writerFailed
        }
        writer.add(input)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )

        if includeAudio {
            let audioInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 128_000
                ]
            )
            audioInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(audioInput) else {
                throw ScreenRecorderError.writerFailed
            }
            writer.add(audioInput)
            audioWriterInput = audioInput
        } else {
            audioWriterInput = nil
        }

        // Write in fragments so a crash mid-take leaves a recoverable movie.
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        assetWriter = writer
        writerInput = input
        pixelBufferAdaptor = adaptor
    }

    private func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isRecording,
              let writerInput,
              writerInput.isReadyForMoreMediaData,
              let assetWriter,
              assetWriter.status == .writing,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let isFirstFrame = firstSampleTime == nil
        if isFirstFrame {
            firstSampleTime = presentationTime
        }

        let relativeTime = CMTimeSubtract(presentationTime, firstSampleTime ?? .zero)
        let frameDuration = resolvedFrameDuration(for: sampleBuffer)

        // The camera is recorded to its own track (CameraTrackWriter) and composited at
        // render time, so screen frames are written untouched.
        let bufferToWrite = pixelBuffer

        let appended: Bool
        if let adaptor = pixelBufferAdaptor {
            appended = adaptor.append(bufferToWrite, withPresentationTime: relativeTime)
        } else {
            appended = false
        }

        if !appended {
            reportFailure(assetWriter.error ?? ScreenRecorderError.writerFailed)
            return
        }

        lastWrittenTime = CMTimeAdd(relativeTime, frameDuration)
        lastWrittenPixelBuffer = bufferToWrite

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if isFirstFrame, !self.didNotifyFirstFrame {
                self.didNotifyFirstFrame = true
                self.delegate?.screenRecorder(self, didReceiveFirstFrameAt: presentationTime)
            }
            self.delegate?.screenRecorder(self, didWriteFrameAt: CMTimeGetSeconds(relativeTime))
        }
    }

    private func writeAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer, hostTime: CMTime) {
        guard isRecording,
              let audioWriterInput,
              audioWriterInput.isReadyForMoreMediaData,
              let assetWriter,
              assetWriter.status == .writing,
              let firstSampleTime
        else { return }

        // Place audio on the video's timeline (t = 0 is the first video frame) rather than
        // starting at the mic's own first sample, which shifted narration by however long
        // the mic took to start. Buffers captured before t = 0 are dropped.
        let recordingTime = MediaTiming.recordingTime(hostTime: hostTime, firstVideoFrameHostTime: firstSampleTime)
        guard recordingTime.isValid, recordingTime >= .zero else { return }

        let offset = CMTimeSubtract(recordingTime, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard let retimed = sampleBuffer.retimed(by: offset) else { return }
        if !audioWriterInput.append(retimed) {
            reportFailure(assetWriter.error ?? ScreenRecorderError.writerFailed)
        }
    }

    /// Reports a capture failure once per recording (appends keep failing after the first).
    /// Called on the writer queue.
    private func reportFailure(_ error: Error) {
        guard !didReportFailure else { return }
        didReportFailure = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.screenRecorder(self, didFailWith: error)
        }
    }

    /// ScreenCaptureKit often reports invalid/zero sample durations — fall back to 1/fps.
    private func resolvedFrameDuration(for sampleBuffer: CMSampleBuffer) -> CMTime {
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        if duration.isValid && !duration.isIndefinite && duration.seconds > 0 {
            return duration
        }
        return CMTime(value: 1, timescale: CMTimeScale(max(fps, 1)))
    }
}

extension ScreenRecorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        appendSampleBuffer(sampleBuffer)
    }
}

extension ScreenRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        writerQueue.async { [weak self] in
            self?.reportFailure(error)
        }
    }
}

struct RecordingResult {
    let videoURL: URL
    let duration: TimeInterval
    let width: Int
    let height: Int
    let fps: Int
    let scaleFactor: CGFloat
    let captureOrigin: CGPoint
    let captureSize: CGSize
    let windowTitle: String?
    let appName: String?
}

enum ScreenRecorderError: LocalizedError {
    case noDisplayAvailable
    case windowNotAvailable
    case notRecording
    case writerFailed
    case alreadyRecording
    case noFramesCaptured

    var errorDescription: String? {
        switch self {
        case .noDisplayAvailable:
            return "No display is available for screen recording."
        case .windowNotAvailable:
            return "The selected window is no longer available."
        case .notRecording:
            return "Recording is not active."
        case .writerFailed:
            return "Failed to write the screen recording."
        case .alreadyRecording:
            return "A recording is already in progress."
        case .noFramesCaptured:
            return "No frames were captured, so nothing was saved."
        }
    }
}
