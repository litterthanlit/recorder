import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

protocol CameraMicCaptureDelegate: AnyObject {
    /// `hostTime` is the buffer's capture time converted to the host clock.
    func cameraMicCapture(
        _ capture: CameraMicCapture,
        didOutputAudioSampleBuffer sampleBuffer: CMSampleBuffer,
        hostTime: CMTime
    )
    func cameraMicCapture(_ capture: CameraMicCapture, didFailWith error: Error)
}

final class CameraMicCapture: NSObject {
    weak var delegate: CameraMicCaptureDelegate?

    /// Called on the capture queue whenever a (possibly processed) camera frame is ready.
    var onCameraFrame: ((CVPixelBuffer) -> Void)? {
        get {
            bufferLock.lock()
            defer { bufferLock.unlock() }
            return _onCameraFrame
        }
        set {
            bufferLock.lock()
            _onCameraFrame = newValue
            bufferLock.unlock()
        }
    }

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.recorder.camera-mic.session")
    /// Camera frames can take a while (Vision person segmentation for backgrounds), so they
    /// get their own queue; sharing one with the mic delayed and dropped audio buffers.
    private let videoQueue = DispatchQueue(label: "com.recorder.camera-mic.video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "com.recorder.camera-mic.audio", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let bufferLock = NSLock()
    private var latestCameraBuffer: CVPixelBuffer?
    private var _onCameraFrame: ((CVPixelBuffer) -> Void)?
    private var isRunning = false
    private let backgroundProcessor = CameraBackgroundProcessor()
    private var backgroundMode: CameraBackgroundMode = .none

    private(set) var previewLayer: AVCaptureVideoPreviewLayer?

    /// Records processed camera frames to their own movie while a take is running.
    let trackWriter = CameraTrackWriter()

    var currentCameraPixelBuffer: CVPixelBuffer? {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return latestCameraBuffer
    }

    func start(
        enableCamera: Bool,
        cameraID: String?,
        enableMicrophone: Bool,
        microphoneID: String?,
        cameraBackground: CameraBackgroundMode = .none
    ) throws {
        guard enableCamera || enableMicrophone else { return }
        guard !isRunning else { return }

        bufferLock.lock()
        backgroundMode = cameraBackground
        bufferLock.unlock()

        try sessionQueue.sync {
            session.beginConfiguration()
            defer { session.commitConfiguration() }

            session.sessionPreset = .high

            for input in session.inputs {
                session.removeInput(input)
            }
            for output in session.outputs {
                session.removeOutput(output)
            }

            if enableCamera {
                let device = resolveDevice(mediaType: .video, preferredID: cameraID)
                    ?? AVCaptureDevice.default(for: .video)
                guard let device else {
                    throw CameraMicCaptureError.cameraUnavailable
                }
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else {
                    throw CameraMicCaptureError.cameraUnavailable
                }
                session.addInput(input)

                videoOutput.alwaysDiscardsLateVideoFrames = true
                videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
                guard session.canAddOutput(videoOutput) else {
                    throw CameraMicCaptureError.cameraUnavailable
                }
                session.addOutput(videoOutput)

                if let connection = videoOutput.connection(with: .video),
                   connection.isVideoMirroringSupported {
                    // Must disable automatic mirroring before setting `isVideoMirrored`,
                    // otherwise AVFoundation throws NSInvalidArgumentException.
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = true
                }
            }

            if enableMicrophone {
                let device = resolveDevice(mediaType: .audio, preferredID: microphoneID)
                    ?? AVCaptureDevice.default(for: .audio)
                guard let device else {
                    throw CameraMicCaptureError.microphoneUnavailable
                }
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else {
                    throw CameraMicCaptureError.microphoneUnavailable
                }
                session.addInput(input)

                // Normalize native mic formats (16 kHz Bluetooth HFP, 96 kHz USB, multi-channel
                // MacBook arrays) to 48 kHz mono PCM so AAC encoding always accepts them.
                audioOutput.audioSettings = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]
                audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
                guard session.canAddOutput(audioOutput) else {
                    throw CameraMicCaptureError.microphoneUnavailable
                }
                session.addOutput(audioOutput)
            }
        }

        // Raw preview layer only when no virtual background — effects need processed frames.
        if enableCamera, !cameraBackground.requiresProcessing {
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            previewLayer = layer
        } else {
            previewLayer = nil
        }

        sessionQueue.async { [weak self] in
            self?.session.startRunning()
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        bufferLock.lock()
        _onCameraFrame = nil
        latestCameraBuffer = nil
        backgroundMode = .none
        bufferLock.unlock()
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
        }
        previewLayer = nil
    }

    /// Capture timestamps are on the session's clock; convert to the host clock that
    /// ScreenCaptureKit (and `CACurrentMediaTime()`) use so camera and screen line up.
    private func hostTime(of sampleBuffer: CMSampleBuffer) -> CMTime {
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard let sessionClock = session.synchronizationClock else { return time }
        return CMSyncConvertTime(time, from: sessionClock, to: CMClockGetHostTimeClock())
    }

    private func resolveDevice(mediaType: AVMediaType, preferredID: String?) -> AVCaptureDevice? {
        if let preferredID,
           let device = AVCaptureDevice(uniqueID: preferredID),
           device.hasMediaType(mediaType) {
            return device
        }
        return AVCaptureDevice.default(for: mediaType)
    }

    private func storeCameraFrame(_ pixelBuffer: CVPixelBuffer, hostTime: CMTime) {
        autoreleasepool {
            bufferLock.lock()
            let mode = backgroundMode
            let frameHandler = _onCameraFrame
            bufferLock.unlock()

            let output: CVPixelBuffer
            if mode.requiresProcessing {
                output = backgroundProcessor.process(pixelBuffer, mode: mode) ?? pixelBuffer
            } else {
                output = pixelBuffer
            }

            bufferLock.lock()
            latestCameraBuffer = output
            bufferLock.unlock()
            trackWriter.append(output, hostTime: hostTime)
            frameHandler?(output)
        }
    }
}

extension CameraMicCapture: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output === videoOutput {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            storeCameraFrame(pixelBuffer, hostTime: hostTime(of: sampleBuffer))
            return
        }

        if output === audioOutput {
            delegate?.cameraMicCapture(
                self,
                didOutputAudioSampleBuffer: sampleBuffer,
                hostTime: hostTime(of: sampleBuffer)
            )
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Dropped frames are expected under load; ignore.
    }
}

enum CameraMicCaptureError: LocalizedError {
    case cameraUnavailable
    case microphoneUnavailable

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable:
            return "No camera is available."
        case .microphoneUnavailable:
            return "No microphone is available."
        }
    }
}
