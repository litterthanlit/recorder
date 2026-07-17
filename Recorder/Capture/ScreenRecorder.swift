import AppKit
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

protocol ScreenRecorderDelegate: AnyObject {
    func screenRecorderDidReceiveFirstFrame(_ recorder: ScreenRecorder)
    func screenRecorder(_ recorder: ScreenRecorder, didWriteFrameAt time: TimeInterval)
    func screenRecorder(_ recorder: ScreenRecorder, didFailWith error: Error)
}

struct ScreenRecorderOptions {
    var captureTarget: CaptureTargetKind = .display
    var windowID: UInt32?
    var showCursor: Bool = true
}

final class ScreenRecorder: NSObject {
    weak var delegate: ScreenRecorderDelegate?

    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var sessionStartTime: TimeInterval = 0
    private var firstSampleTime: CMTime?
    private var lastWrittenTime: CMTime = .zero
    private var outputURL: URL?
    private var isRecording = false
    private var didNotifyFirstFrame = false
    private let writerQueue = DispatchQueue(label: "com.recorder.writer")

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
        guard !isRecording else { return }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        let filter: SCContentFilter
        let displayScale: CGFloat

        switch options.captureTarget {
        case .display:
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                throw ScreenRecorderError.noDisplayAvailable
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
            displayScale = NSScreen.main?.backingScaleFactor ?? 2
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
            let screen = NSScreen.screens.first { $0.frame.contains(windowCenter) } ?? NSScreen.main
            let display = content.displays.first(where: { $0.displayID == screen?.displayIdentifier })
                ?? content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first
            guard let display else {
                throw ScreenRecorderError.noDisplayAvailable
            }
            filter = SCContentFilter(display: display, including: [window])
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

        try setupWriter(outputURL: url, width: captureWidth, height: captureHeight)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: writerQueue)
        try await stream.startCapture()

        self.stream = stream
        sessionStartTime = CACurrentMediaTime()
        firstSampleTime = nil
        lastWrittenTime = .zero
        didNotifyFirstFrame = false
        outputURL = url
        isRecording = true
    }

    func stopRecording() async throws -> RecordingResult {
        guard isRecording else {
            throw ScreenRecorderError.notRecording
        }

        isRecording = false

        if let stream {
            try await stream.stopCapture()
        }
        stream = nil

        return try await withCheckedThrowingContinuation { continuation in
            writerQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: ScreenRecorderError.notRecording)
                    return
                }

                do {
                    self.writerInput?.markAsFinished()
                    let writer = self.assetWriter
                    let outputURL = self.outputURL

                    writer?.finishWriting {
                        if writer?.status == .failed {
                            continuation.resume(throwing: writer?.error ?? ScreenRecorderError.writerFailed)
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
    }

    private func configureCaptureGeometry(display: SCDisplay, displayScale: CGFloat) {
        let logicalWidth = Int(display.width)
        let logicalHeight = Int(display.height)
        captureWidth = Int(Double(logicalWidth) * displayScale)
        captureHeight = Int(Double(logicalHeight) * displayScale)

        if let screen = NSScreen.screens.first(where: { $0.displayIdentifier == display.displayID }) ?? NSScreen.main {
            captureOrigin = screen.frame.origin
            captureSizePoints = screen.frame.size
        } else {
            captureOrigin = .zero
            captureSizePoints = CGSize(width: logicalWidth, height: logicalHeight)
        }
    }

    private func configureWindowGeometry(window: SCWindow, displayScale: CGFloat) {
        let frame = window.frame
        captureOrigin = frame.origin
        captureSizePoints = frame.size
        captureWidth = Int(frame.width * displayScale)
        captureHeight = Int(frame.height * displayScale)
    }

    private func setupWriter(outputURL: URL, width: Int, height: Int) throws {
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
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        assetWriter = writer
        writerInput = input
    }

    private func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isRecording,
              let writerInput,
              writerInput.isReadyForMoreMediaData,
              let assetWriter,
              assetWriter.status == .writing
        else { return }

        guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let isFirstFrame = firstSampleTime == nil
        if isFirstFrame {
            firstSampleTime = presentationTime
        }

        let relativeTime = CMTimeSubtract(presentationTime, firstSampleTime ?? .zero)
        let frameDuration = resolvedFrameDuration(for: sampleBuffer)

        var timingInfo = CMSampleTimingInfo(
            duration: frameDuration,
            presentationTimeStamp: relativeTime,
            decodeTimeStamp: .invalid
        )

        var copiedBuffer: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleBufferOut: &copiedBuffer
        )

        guard let copiedBuffer else { return }

        if !writerInput.append(copiedBuffer) {
            delegate?.screenRecorder(self, didFailWith: assetWriter.error ?? ScreenRecorderError.writerFailed)
            return
        }

        lastWrittenTime = CMTimeAdd(relativeTime, frameDuration)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if isFirstFrame, !self.didNotifyFirstFrame {
                self.didNotifyFirstFrame = true
                self.delegate?.screenRecorderDidReceiveFirstFrame(self)
            }
            self.delegate?.screenRecorder(self, didWriteFrameAt: CMTimeGetSeconds(relativeTime))
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
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.screenRecorder(self, didFailWith: error)
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
    case screenCapturePermissionDenied

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
        case .screenCapturePermissionDenied:
            return "Screen Recording permission is required."
        }
    }
}
