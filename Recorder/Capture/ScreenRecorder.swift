import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
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
    var excludeWindowIDs: [UInt32] = []
    var enableMicrophone: Bool = false
    var enableCamera: Bool = false
    var cameraPosition: CameraBubblePosition = .bottomRight
    var cameraFrameProvider: (() -> CVPixelBuffer?)?
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
    private var firstAudioSampleTime: CMTime?
    private var lastWrittenTime: CMTime = .zero
    private var outputURL: URL?
    private var isRecording = false
    private var didNotifyFirstFrame = false
    private let writerQueue = DispatchQueue(label: "com.recorder.writer")
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
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
        guard !isRecording else { return }
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

        try setupWriter(
            outputURL: url,
            width: captureWidth,
            height: captureHeight,
            includeAudio: options.enableMicrophone
        )

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: writerQueue)
        try await stream.startCapture()

        self.stream = stream
        sessionStartTime = CACurrentMediaTime()
        firstSampleTime = nil
        firstAudioSampleTime = nil
        lastWrittenTime = .zero
        didNotifyFirstFrame = false
        outputURL = url
        isRecording = true
    }

    func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        writerQueue.async { [weak self] in
            self?.writeAudioSampleBuffer(sampleBuffer)
        }
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

                self.writerInput?.markAsFinished()
                self.audioWriterInput?.markAsFinished()
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

        let bufferToWrite: CVPixelBuffer
        if options.enableCamera,
           let cameraBuffer = options.cameraFrameProvider?(),
           let composited = compositeCamera(onto: pixelBuffer, camera: cameraBuffer) {
            bufferToWrite = composited
        } else {
            bufferToWrite = pixelBuffer
        }

        let appended: Bool
        if let adaptor = pixelBufferAdaptor {
            appended = adaptor.append(bufferToWrite, withPresentationTime: relativeTime)
        } else {
            appended = false
        }

        if !appended {
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

    private func writeAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isRecording,
              let audioWriterInput,
              audioWriterInput.isReadyForMoreMediaData,
              let assetWriter,
              assetWriter.status == .writing,
              let firstSampleTime
        else { return }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstAudioSampleTime == nil {
            firstAudioSampleTime = presentationTime
        }

        // Align mic audio to the same zero as the first video frame using wall-clock offset
        // between streams is imperfect; prefer PTS relative to first audio sample once video started.
        let relativeTime = CMTimeSubtract(presentationTime, firstAudioSampleTime ?? presentationTime)
        guard relativeTime.isValid, relativeTime.seconds >= 0 else { return }

        var timingInfo = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
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
        if !audioWriterInput.append(copiedBuffer) {
            delegate?.screenRecorder(self, didFailWith: assetWriter.error ?? ScreenRecorderError.writerFailed)
        }
    }

    private func compositeCamera(onto screenBuffer: CVPixelBuffer, camera: CVPixelBuffer) -> CVPixelBuffer? {
        let screenImage = CIImage(cvPixelBuffer: screenBuffer)
        let bounds = screenImage.extent
        let bubbleRect = CameraBubbleLayout.frame(
            in: bounds.size,
            position: options.cameraPosition
        )

        let cameraImage = CIImage(cvPixelBuffer: camera)
        let camExtent = cameraImage.extent
        let scale = max(bubbleRect.width / camExtent.width, bubbleRect.height / camExtent.height)
        let scaled = cameraImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let scaledExtent = scaled.extent
        let cropOrigin = CGPoint(
            x: scaledExtent.midX - bubbleRect.width / 2,
            y: scaledExtent.midY - bubbleRect.height / 2
        )
        let cropped = scaled.cropped(
            to: CGRect(origin: cropOrigin, size: bubbleRect.size)
        )
        let positioned = cropped.transformed(
            by: CGAffineTransform(
                translationX: bubbleRect.minX - cropped.extent.minX,
                y: bubbleRect.minY - cropped.extent.minY
            )
        )

        let borderWidth = min(bounds.width, bounds.height) * CameraBubbleLayout.borderWidthFraction
        let borderRect = bubbleRect.insetBy(dx: -borderWidth, dy: -borderWidth)
        let whiteBorder = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.92))
            .cropped(to: borderRect)
        let borderMask = circularMask(rect: borderRect, canvas: bounds)
        let maskedBorder = whiteBorder.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputMaskImageKey: borderMask
        ])

        let bubbleMask = circularMask(rect: bubbleRect, canvas: bounds)
        let maskedCamera = positioned.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputMaskImageKey: bubbleMask
        ])

        let composed = maskedCamera
            .composited(over: maskedBorder)
            .composited(over: screenImage)
            .cropped(to: bounds)

        var output: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(bounds.width),
            Int(bounds.height),
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ] as CFDictionary,
            &output
        )
        guard status == kCVReturnSuccess, let output else { return nil }
        ciContext.render(composed, to: output)
        return output
    }

    private func circularMask(rect: CGRect, canvas: CGRect) -> CIImage {
        let width = max(1, Int(canvas.width))
        let height = max(1, Int(canvas.height))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return CIImage(color: .white).cropped(to: canvas)
        }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(NSColor.white.cgColor)
        context.fillEllipse(in: rect)

        guard let cgImage = context.makeImage() else {
            return CIImage(color: .white).cropped(to: canvas)
        }
        return CIImage(cgImage: cgImage)
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
