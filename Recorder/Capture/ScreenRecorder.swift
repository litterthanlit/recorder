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
    /// Display to record in `.display` and `.area` mode; `nil` means the main display.
    var displayID: UInt32?
    /// In `.area` mode, the part of the display to record (display points, top-left origin).
    var area: CGRect?
    /// The take's clock: the first frame sets its t = 0, and pauses come from it.
    var clock = RecordingClock()
    var frameRate: Int = 60
    var hideDesktopIcons = false
    var hideNotifications = false
    var showCursor: Bool = true
    /// Leave the menu bar out of display recordings. (Hiding it doesn't work: presentation
    /// options only apply while this app is frontmost, and it isn't while recording.)
    var cropsMenuBar: Bool = false
    var excludeWindowIDs: [UInt32] = []
    var enableMicrophone: Bool = false
    /// Record what the Mac plays (other apps' audio) as its own track.
    var captureSystemAudio: Bool = false
}

/// Unchecked: capture and writer state is confined to `writerQueue`; the rest is set up
/// before capture starts.
final class ScreenRecorder: NSObject, @unchecked Sendable {
    weak var delegate: ScreenRecorderDelegate?

    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioWriterInput: AVAssetWriterInput?
    private var systemAudioWriterInput: AVAssetWriterInput?
    private var sessionStartTime: TimeInterval = 0
    private var firstSampleTime: CMTime?
    private var lastWrittenTime: CMTime = .zero
    private var outputURL: URL?
    private var isRecording = false
    private var didNotifyFirstFrame = false
    private var didReportFailure = false
    /// Presentation time of the last frame written (writer queue only); timestamps must
    /// keep increasing, including across a pause.
    private var lastAppendedTime = CMTime.invalid
    /// The newest frame delivered while paused, written when the take resumes so the
    /// video doesn't show the pre-pause screen until something changes.
    private var pausedPixelBuffer: CVPixelBuffer?
    private var filterRefreshTimer: Timer?
    private var excludedFinderWindowIDs: Set<UInt32> = []
    /// Samples the writer wasn't ready for (writer queue only). Logged at stop: dropped
    /// audio shifts later narration earlier, so these should stay at zero.
    private var droppedVideoFrames = 0
    private var droppedAudioBuffers = 0
    /// Last frame handed to the writer; re-appended at stop so a still ending isn't cut off.
    private var lastWrittenPixelBuffer: CVPixelBuffer?
    private let writerQueue = DispatchQueue(label: "com.recorder.writer")
    private var options = ScreenRecorderOptions()

    private(set) var captureWidth: Int = 0
    private(set) var captureHeight: Int = 0
    private(set) var fps: Int = 60
    private(set) var scaleFactor: CGFloat = 2
    private(set) var captureOrigin: CGPoint = .zero
    /// Part of the display recorded, in display points (top-left origin); `nil` for all.
    private var displaySourceRect: CGRect?
    private(set) var captureSizePoints: CGSize = .zero
    private(set) var windowTitle: String?
    private(set) var appName: String?
    /// The recorded window in window mode, `nil` for a display.
    private(set) var capturedWindowID: UInt32?

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
        guard !writerQueue.sync(execute: { isRecording }) else {
            throw ScreenRecorderError.alreadyRecording
        }
        self.options = options

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        let filter: SCContentFilter
        let displayScale: CGFloat

        switch options.captureTarget {
        case .display, .area:
            let displayID = CaptureGeometry.resolvedDisplayID(
                preferred: options.displayID,
                available: content.displays.map(\.displayID),
                main: CGMainDisplayID()
            )
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw ScreenRecorderError.noDisplayAvailable
            }
            filter = makeDisplayFilter(display: display, content: content, options: options)
            // NSScreen.main is the screen with the key window, not necessarily this display.
            let screen = NSScreen.screen(forDisplayID: display.displayID)
            displayScale = screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            windowTitle = nil
            appName = nil
            capturedWindowID = nil

            let displaySize = CGSize(width: display.width, height: display.height)
            let sourceRect: CGRect
            if options.captureTarget == .area {
                guard let area = options.area,
                      let rect = CaptureGeometry.areaSourceRect(area, displaySize: displaySize, scale: displayScale)
                else {
                    throw ScreenRecorderError.areaNotAvailable
                }
                sourceRect = rect
                appName = NSWorkspace.shared.frontmostApplication?.localizedName
            } else {
                // visibleFrame's top inset is the menu bar (0 when it auto-hides).
                let menuBarHeight = options.cropsMenuBar
                    ? screen.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 0
                    : 0
                sourceRect = CaptureGeometry.sourceRect(displaySize: displaySize, topInset: menuBarHeight)
            }
            configureCaptureGeometry(display: display, displayScale: displayScale, sourceRect: sourceRect)

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
            capturedWindowID = window.windowID
            displaySourceRect = nil
            configureWindowGeometry(window: window, displayScale: displayScale)
        }

        scaleFactor = displayScale
        fps = RecordingPreferences.frameRateChoices.contains(options.frameRate) ? options.frameRate : 60

        let configuration = SCStreamConfiguration()
        configuration.width = captureWidth
        configuration.height = captureHeight
        if let displaySourceRect {
            configuration.sourceRect = displaySourceRect
        }
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        configuration.showsCursor = options.showCursor
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 6
        if options.captureSystemAudio {
            configuration.capturesAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            // Leave out this app's own sounds (and avoid feedback from the preview).
            configuration.excludesCurrentProcessAudio = true
        }

        try setupWriter(
            outputURL: url,
            width: captureWidth,
            height: captureHeight,
            includeAudio: options.enableMicrophone,
            includeSystemAudio: options.captureSystemAudio
        )

        outputURL = url

        // Ready the writer-side state before capture starts: the first frame (on a still
        // screen, possibly the only one for a while) can arrive before startCapture()
        // returns, and it must not be dropped. These are read on the writer queue.
        writerQueue.sync {
            firstSampleTime = nil
            lastAppendedTime = .invalid
            pausedPixelBuffer = nil
            droppedVideoFrames = 0
            droppedAudioBuffers = 0
            lastWrittenTime = .zero
            lastWrittenPixelBuffer = nil
            didNotifyFirstFrame = false
            didReportFailure = false
            isRecording = true
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: writerQueue)
            if options.captureSystemAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writerQueue)
            }
            try await stream.startCapture()
        } catch {
            writerQueue.sync {
                isRecording = false
                assetWriter?.cancelWriting()
                assetWriter = nil
            }
            throw error
        }

        self.stream = stream
        sessionStartTime = CACurrentMediaTime()
        startFilterRefreshIfNeeded(display: options.captureTarget == .window ? nil : filterDisplay)
    }

    // MARK: - Content filter

    /// The display a display or area recording captures, for refreshing its filter.
    private var filterDisplay: SCDisplay?

    /// Leaves out this app's windows (camera bubble, countdown, HUD, panel, editor: the
    /// camera is recorded separately and composited at export) and, on request,
    /// notification banners and desktop icons.
    private func makeDisplayFilter(display: SCDisplay, content: SCShareableContent, options: ScreenRecorderOptions) -> SCContentFilter {
        filterDisplay = display
        let plan = CaptureExclusion.plan(
            ownBundleID: Bundle.main.bundleIdentifier,
            windows: content.windows.map {
                CaptureExclusion.Window(
                    windowID: $0.windowID,
                    bundleID: $0.owningApplication?.bundleIdentifier,
                    layer: $0.windowLayer
                )
            },
            hideDesktopIcons: options.hideDesktopIcons,
            hideNotifications: options.hideNotifications
        )
        excludedFinderWindowIDs = plan.exceptedWindowIDs
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let excludedApps = content.applications.filter {
            plan.excludedBundleIDs.contains($0.bundleIdentifier) || $0.processID == ownPID
        }
        if excludedApps.isEmpty {
            let excludedWindows = content.windows.filter { options.excludeWindowIDs.contains($0.windowID) }
            return SCContentFilter(display: display, excludingWindows: excludedWindows)
        }
        let exceptedWindows = content.windows.filter { plan.exceptedWindowIDs.contains($0.windowID) }
        return SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: exceptedWindows)
    }

    /// With desktop icons hidden, all of Finder is left out except the windows open when
    /// the take started. Check now and then for new Finder windows so they're recorded.
    private func startFilterRefreshIfNeeded(display: SCDisplay?) {
        filterRefreshTimer?.invalidate()
        filterRefreshTimer = nil
        guard options.hideDesktopIcons, display != nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { await self?.refreshFilterIfFinderWindowsChanged() }
        }
        RunLoop.main.add(timer, forMode: .common)
        filterRefreshTimer = timer
    }

    private func refreshFilterIfFinderWindowsChanged() async {
        guard let stream, let display = filterDisplay,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        else { return }
        let finderWindows = Set(content.windows
            .filter { $0.owningApplication?.bundleIdentifier == CaptureExclusion.finderBundleID && $0.windowLayer == 0 }
            .map(\.windowID))
        guard finderWindows != excludedFinderWindowIDs else { return }
        let filter = makeDisplayFilter(display: display, content: content, options: options)
        do {
            try await stream.updateContentFilter(filter)
        } catch {
            Log.capture.error("Updating the capture filter failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Pause

    /// Stops writing samples; the clock leaves the paused time out of the recording.
    func pause() {
        writerQueue.async { [self] in
            guard isRecording else { return }
            options.clock.pause()
            pausedPixelBuffer = nil
        }
    }

    func resume() {
        writerQueue.async { [self] in
            guard isRecording, options.clock.isPaused else { return }
            let host = RecordingClock.now
            options.clock.resume(at: host)
            // The screen may have changed while paused without changing since, in which
            // case no new frame comes: show the newest one from the resume point on.
            guard let buffer = pausedPixelBuffer ?? lastWrittenPixelBuffer,
                  let time = options.clock.recordingTime(forHost: host)
            else { return }
            pausedPixelBuffer = nil
            appendVideoFrame(buffer, at: time)
        }
    }

    /// Stops capture and throws the take away (restart, discard).
    func cancelRecording() async {
        filterRefreshTimer?.invalidate()
        filterRefreshTimer = nil
        let wasRecording = writerQueue.sync {
            let wasRecording = isRecording
            isRecording = false
            return wasRecording
        }
        guard wasRecording else { return }
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        writerQueue.sync {
            assetWriter?.cancelWriting()
            assetWriter = nil
            lastWrittenPixelBuffer = nil
            pausedPixelBuffer = nil
            if let outputURL {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }
    }

    /// - Parameter hostTime: the buffer's capture time on the host clock.
    func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer, hostTime: CMTime) {
        writerQueue.async { [weak self] in
            guard let self, let input = self.audioWriterInput else { return }
            self.writeAudioSampleBuffer(sampleBuffer, hostTime: hostTime, to: input)
        }
    }

    /// Stops capture and finalizes the movie. Safe to call after a stream error: the
    /// writer is always finished so whatever was recorded stays playable.
    func stopRecording() async throws -> RecordingResult {
        let stopHostTime = CMClockGetTime(CMClockGetHostTimeClock())
        filterRefreshTimer?.invalidate()
        filterRefreshTimer = nil
        let wasRecording = writerQueue.sync {
            let wasRecording = isRecording
            isRecording = false
            return wasRecording
        }
        guard wasRecording else {
            throw ScreenRecorderError.notRecording
        }

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
                      self.firstSampleTime != nil
                else {
                    let failedWriter = self.assetWriter
                    failedWriter?.cancelWriting()
                    self.assetWriter = nil
                    continuation.resume(throwing: failedWriter?.error ?? ScreenRecorderError.noFramesCaptured)
                    return
                }

                // ScreenCaptureKit only delivers frames when the screen changes, so a still
                // ending has no frames. Repeat the last frame at the stop time to keep it.
                // Stopping while paused ends where the pause began.
                let stopTime = self.options.clock.activeDuration(atHost: stopHostTime)
                if stopTime > self.lastWrittenTime, let lastBuffer = self.lastWrittenPixelBuffer {
                    self.appendVideoFrame(lastBuffer, at: stopTime)
                    self.lastWrittenTime = CMTimeMaximum(self.lastWrittenTime, stopTime)
                }

                if self.droppedVideoFrames > 0 || self.droppedAudioBuffers > 0 {
                    Log.capture.warning("Writer dropped \(self.droppedVideoFrames) video frames and \(self.droppedAudioBuffers) audio buffers")
                }

                self.writerInput?.markAsFinished()
                self.audioWriterInput?.markAsFinished()
                self.systemAudioWriterInput?.markAsFinished()
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

    /// - Parameter sourceRect: the part of the display recorded, in display points with a
    ///   top-left origin (the whole display, without the menu bar, or an area).
    private func configureCaptureGeometry(display: SCDisplay, displayScale: CGFloat, sourceRect: CGRect) {
        let fullDisplay = CGRect(x: 0, y: 0, width: CGFloat(display.width), height: CGFloat(display.height))
        displaySourceRect = sourceRect == fullDisplay ? nil : sourceRect

        // Global display space (top-left origin), the same space as CGEvent.location.
        // NSScreen.frame is bottom-left based and only matches for the main display.
        let bounds = CGDisplayBounds(display.displayID)
        captureOrigin = CGPoint(x: bounds.minX + sourceRect.minX, y: bounds.minY + sourceRect.minY)
        captureSizePoints = sourceRect.size
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

    private func setupWriter(
        outputURL: URL,
        width: Int,
        height: Int,
        includeAudio: Bool,
        includeSystemAudio: Bool
    ) throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let settings = VideoCodecChoice.forFrame(width: width, height: height).outputSettings(
            width: width,
            height: height,
            compression: [AVVideoAverageBitRateKey: width * height * 4]
        )

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

        if includeSystemAudio {
            let systemInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 192_000
                ]
            )
            systemInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(systemInput) else {
                throw ScreenRecorderError.writerFailed
            }
            writer.add(systemInput)
            systemAudioWriterInput = systemInput
        } else {
            systemAudioWriterInput = nil
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
              let assetWriter,
              assetWriter.status == .writing,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              Self.isCompleteFrame(sampleBuffer)
        else { return }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let isFirstFrame = firstSampleTime == nil
        if isFirstFrame {
            firstSampleTime = presentationTime
            options.clock.setEpoch(presentationTime)
        }

        guard let relativeTime = options.clock.recordingTime(forHost: presentationTime) else {
            // Paused: nothing is written, but keep the newest frame for the resume.
            pausedPixelBuffer = pixelBuffer
            return
        }
        guard writerInput.isReadyForMoreMediaData else {
            droppedVideoFrames += 1
            return
        }

        // The camera is recorded to its own track (CameraTrackWriter) and composited at
        // render time, so screen frames are written untouched.
        guard appendVideoFrame(pixelBuffer, at: relativeTime) else { return }
        lastWrittenTime = CMTimeAdd(relativeTime, resolvedFrameDuration(for: sampleBuffer))

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if isFirstFrame, !self.didNotifyFirstFrame {
                self.didNotifyFirstFrame = true
                self.delegate?.screenRecorder(self, didReceiveFirstFrameAt: presentationTime)
            }
            self.delegate?.screenRecorder(self, didWriteFrameAt: CMTimeGetSeconds(relativeTime))
        }
    }

    /// Writes one frame at `time` on the recording's timeline. Frames at or before the
    /// last one written are skipped (timestamps must increase). Writer queue only.
    @discardableResult
    private func appendVideoFrame(_ pixelBuffer: CVPixelBuffer, at time: CMTime) -> Bool {
        if lastAppendedTime.isValid, time <= lastAppendedTime {
            return false
        }
        guard let adaptor = pixelBufferAdaptor,
              let writerInput,
              writerInput.isReadyForMoreMediaData,
              let assetWriter
        else { return false }
        guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
            reportFailure(assetWriter.error ?? ScreenRecorderError.writerFailed)
            return false
        }
        lastAppendedTime = time
        lastWrittenPixelBuffer = pixelBuffer
        if time > lastWrittenTime {
            lastWrittenTime = time
        }
        return true
    }

    /// Called on the writer queue with a mic or system audio buffer.
    private func writeAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer, hostTime: CMTime, to audioWriterInput: AVAssetWriterInput) {
        guard isRecording,
              let assetWriter,
              assetWriter.status == .writing,
              firstSampleTime != nil
        else { return }

        // Place audio on the video's timeline (t = 0 is the first video frame, paused time
        // left out) rather than starting at the mic's own first sample, which shifted
        // narration by however long the mic took to start. Audio from before t = 0 or
        // while paused is dropped; a buffer that straddles a pause edge is trimmed.
        guard let kept = keptAudio(sampleBuffer, hostTime: hostTime),
              let recordingTime = options.clock.recordingTime(forHost: kept.hostTime)
        else { return }
        let buffer = kept.buffer
        guard audioWriterInput.isReadyForMoreMediaData else {
            droppedAudioBuffers += 1
            return
        }

        let offset = CMTimeSubtract(recordingTime, CMSampleBufferGetPresentationTimeStamp(buffer))
        guard let retimed = buffer.retimed(by: offset) else { return }
        if !audioWriterInput.append(retimed) {
            reportFailure(assetWriter.error ?? ScreenRecorderError.writerFailed)
        }
    }

    /// The part of an audio buffer to record, with its capture time on the host clock.
    private func keptAudio(_ sampleBuffer: CMSampleBuffer, hostTime: CMTime) -> (buffer: CMSampleBuffer, hostTime: CMTime)? {
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        guard duration.isValid, duration > .zero else {
            // No duration to trim by: all or nothing.
            return options.clock.recordingTime(forHost: hostTime) == nil ? nil : (sampleBuffer, hostTime)
        }
        guard let kept = options.clock.keptRange(bufferStart: hostTime, duration: duration) else { return nil }
        let endHostTime = CMTimeAdd(hostTime, duration)
        if kept.start == hostTime, kept.end == endHostTime {
            return (sampleBuffer, hostTime)
        }

        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 1 else { return nil }
        let secondsPerSample = CMTimeGetSeconds(duration) / Double(sampleCount)
        let first = Int((CMTimeGetSeconds(CMTimeSubtract(kept.start, hostTime)) / secondsPerSample).rounded())
        let count = Int((CMTimeGetSeconds(kept.duration) / secondsPerSample).rounded())
        guard first >= 0, count > 0, first + count <= sampleCount else { return nil }

        var trimmed: CMSampleBuffer?
        let status = CMSampleBufferCopySampleBufferForRange(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleRange: CFRange(location: first, length: count),
            sampleBufferOut: &trimmed
        )
        guard status == OSStatus(noErr), let trimmed else { return nil }
        let trimmedHostTime = CMTimeAdd(hostTime, CMTime(seconds: Double(first) * secondsPerSample, preferredTimescale: 1_000_000_000))
        return (trimmed, trimmedHostTime)
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

    /// Only `.complete` frames carry new content; idle, blank and suspended ones don't.
    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus)
        else {
            // No status attached: trust the image buffer.
            return true
        }
        return status == .complete
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
        switch type {
        case .screen:
            appendSampleBuffer(sampleBuffer)
        case .audio:
            // System audio is stamped on the host clock, like the screen frames.
            guard sampleBuffer.isValid, let systemAudioWriterInput else { return }
            writeAudioSampleBuffer(
                sampleBuffer,
                hostTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                to: systemAudioWriterInput
            )
        default:
            break
        }
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
    case areaNotAvailable

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
        case .areaNotAvailable:
            return "The selected area isn't on a connected display. Select it again."
        }
    }
}
