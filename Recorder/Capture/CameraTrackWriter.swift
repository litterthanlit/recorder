import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Records (already mirrored / background-processed) camera frames to their own movie.
///
/// Timestamps are relative to the screen recording's first frame, so camera time `t`
/// lines up with screen time `t`. Keeping the camera separate means the renderer can
/// place the bubble in output space: it isn't zoomed with the screen, keeps updating
/// while the screen is still, and can be moved or hidden after recording.
///
/// All state lives on a private serial queue; the public methods can be called from
/// any thread.
final class CameraTrackWriter {
    private let queue = DispatchQueue(label: "com.recorder.camera-track-writer")
    private var outputURL: URL?
    private var epoch: CMTime?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var lastFrameTime = CMTime.invalid
    private var isActive = false

    /// Starts a new take. Frames are ignored until `setEpoch` is called.
    func prepare(outputURL: URL) {
        queue.async { [self] in
            resetWriter(cancelling: true)
            try? FileManager.default.removeItem(at: outputURL)
            self.outputURL = outputURL
            epoch = nil
            isActive = true
        }
    }

    /// Host time of the screen recording's first frame (its t = 0).
    func setEpoch(_ hostTime: CMTime) {
        queue.async { [self] in
            if epoch == nil {
                epoch = hostTime
            }
        }
    }

    /// - Parameter hostTime: when the frame was captured, on the host clock.
    func append(_ pixelBuffer: CVPixelBuffer, hostTime: CMTime) {
        queue.async { [self] in
            guard isActive, let epoch, let outputURL else { return }

            let time = CMTimeSubtract(hostTime, epoch)
            guard time.isValid, time >= .zero else { return }
            if lastFrameTime.isValid, time <= lastFrameTime { return }

            if writer == nil {
                do {
                    try setUpWriter(
                        outputURL: outputURL,
                        width: CVPixelBufferGetWidth(pixelBuffer),
                        height: CVPixelBufferGetHeight(pixelBuffer)
                    )
                } catch {
                    // The screen recording matters more; carry on without a camera track.
                    isActive = false
                    return
                }
            }

            guard let activeWriter = writer, activeWriter.status == .writing,
                  let activeInput = input, activeInput.isReadyForMoreMediaData,
                  let activeAdaptor = adaptor
            else { return }

            if activeAdaptor.append(pixelBuffer, withPresentationTime: time) {
                lastFrameTime = time
            }
        }
    }

    /// Finalizes the camera movie. Returns its URL, or `nil` if no camera frames were
    /// recorded (camera off, or it never produced a frame after recording started).
    func finish() async -> URL? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            queue.async { [self] in
                isActive = false
                guard let activeWriter = writer, activeWriter.status == .writing,
                      lastFrameTime.isValid, let finishedURL = outputURL
                else {
                    resetWriter(cancelling: true)
                    continuation.resume(returning: nil)
                    return
                }

                input?.markAsFinished()
                activeWriter.endSession(atSourceTime: lastFrameTime)
                activeWriter.finishWriting { [weak self] in
                    let url = activeWriter.status == .completed ? finishedURL : nil
                    self?.queue.async {
                        self?.resetWriter(cancelling: false)
                    }
                    continuation.resume(returning: url)
                }
            }
        }
    }

    /// Abandons the current take's camera track.
    func cancel() {
        queue.async { [self] in
            isActive = false
            resetWriter(cancelling: true)
        }
    }

    private func setUpWriter(outputURL: URL, width: Int, height: Int) throws {
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: max(2_000_000, width * height * 4),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
        )
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw CameraTrackWriterError.setupFailed
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

        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        guard writer.startWriting() else {
            throw writer.error ?? CameraTrackWriterError.setupFailed
        }
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        lastFrameTime = .invalid
    }

    private func resetWriter(cancelling: Bool) {
        if cancelling, let activeWriter = writer, activeWriter.status == .writing {
            activeWriter.cancelWriting()
        }
        writer = nil
        input = nil
        adaptor = nil
        lastFrameTime = .invalid
    }
}

enum CameraTrackWriterError: Error {
    case setupFailed
}
