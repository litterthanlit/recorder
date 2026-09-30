import AVFoundation
import Foundation

struct MediaDeviceInfo: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
}

enum CameraBackgroundMode: String, Codable, CaseIterable, Identifiable {
    case none
    case white
    case studio
    case blur
    case gradient

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .white: return "White"
        case .studio: return "Studio"
        case .blur: return "Blur"
        case .gradient: return "Gradient"
        }
    }

    var requiresProcessing: Bool { self != .none }
}

enum MediaDevices {
    static func cameras() -> [MediaDeviceInfo] {
        let deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera]
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        ).devices.map { MediaDeviceInfo(id: $0.uniqueID, name: $0.localizedName) }
    }

    static func microphones() -> [MediaDeviceInfo] {
        let deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInMicrophone, .external]
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        ).devices.map { MediaDeviceInfo(id: $0.uniqueID, name: $0.localizedName) }
    }

    static func defaultCameraID() -> String? {
        AVCaptureDevice.default(for: .video)?.uniqueID ?? cameras().first?.id
    }

    static func defaultMicrophoneID() -> String? {
        AVCaptureDevice.default(for: .audio)?.uniqueID ?? microphones().first?.id
    }
}
