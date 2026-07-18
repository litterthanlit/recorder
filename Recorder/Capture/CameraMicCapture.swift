import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

protocol CameraMicCaptureDelegate: AnyObject {
    func cameraMicCapture(_ capture: CameraMicCapture, didOutputAudioSampleBuffer sampleBuffer: CMSampleBuffer)
    func cameraMicCapture(_ capture: CameraMicCapture, didFailWith error: Error)
}

final class CameraMicCapture: NSObject {
    weak var delegate: CameraMicCaptureDelegate?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.recorder.camera-mic.session")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let bufferLock = NSLock()
    private var latestCameraBuffer: CVPixelBuffer?
    private var isRunning = false

    private(set) var previewLayer: AVCaptureVideoPreviewLayer?

    var currentCameraPixelBuffer: CVPixelBuffer? {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return latestCameraBuffer
    }

    func start(
        enableCamera: Bool,
        cameraID: String?,
        enableMicrophone: Bool,
        microphoneID: String?
    ) throws {
        guard enableCamera || enableMicrophone else { return }
        guard !isRunning else { return }

        session.beginConfiguration()
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
            videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
            guard session.canAddOutput(videoOutput) else {
                throw CameraMicCaptureError.cameraUnavailable
            }
            session.addOutput(videoOutput)

            if let connection = videoOutput.connection(with: .video) {
                if connection.isVideoMirroringSupported {
                    connection.isVideoMirrored = true
                }
            }

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            previewLayer = layer
        } else {
            previewLayer = nil
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

            audioOutput.setSampleBufferDelegate(self, queue: sessionQueue)
            guard session.canAddOutput(audioOutput) else {
                throw CameraMicCaptureError.microphoneUnavailable
            }
            session.addOutput(audioOutput)
        }

        session.commitConfiguration()
        sessionQueue.async { [weak self] in
            self?.session.startRunning()
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
        }
        bufferLock.lock()
        latestCameraBuffer = nil
        bufferLock.unlock()
        previewLayer = nil
    }

    private func resolveDevice(mediaType: AVMediaType, preferredID: String?) -> AVCaptureDevice? {
        if let preferredID,
           let device = AVCaptureDevice(uniqueID: preferredID),
           device.hasMediaType(mediaType) {
            return device
        }
        return AVCaptureDevice.default(for: mediaType)
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
            bufferLock.lock()
            latestCameraBuffer = pixelBuffer
            bufferLock.unlock()
            return
        }

        if output === audioOutput {
            delegate?.cameraMicCapture(self, didOutputAudioSampleBuffer: sampleBuffer)
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
