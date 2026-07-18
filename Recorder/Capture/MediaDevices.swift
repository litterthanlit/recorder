import AVFoundation
import Foundation

struct MediaDeviceInfo: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
}

enum CameraBubblePosition: String, Codable, CaseIterable, Identifiable {
    case bottomRight
    case bottomLeft
    case topRight
    case topLeft

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bottomRight: return "Bottom Right"
        case .bottomLeft: return "Bottom Left"
        case .topRight: return "Top Right"
        case .topLeft: return "Top Left"
        }
    }
}

enum MediaDevices {
    static func cameras() -> [MediaDeviceInfo] {
        var deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            deviceTypes.append(contentsOf: [.external, .continuityCamera])
        }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        ).devices.map { MediaDeviceInfo(id: $0.uniqueID, name: $0.localizedName) }
    }

    static func microphones() -> [MediaDeviceInfo] {
        var deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInMicrophone]
        if #available(macOS 14.0, *) {
            deviceTypes.append(.external)
        }
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

enum CameraBubbleLayout {
    /// Bubble diameter as a fraction of the shorter frame edge.
    static let diameterFraction: CGFloat = 0.18
    static let paddingFraction: CGFloat = 0.035
    static let borderWidthFraction: CGFloat = 0.008

    static func frame(in bounds: CGSize, position: CameraBubblePosition) -> CGRect {
        let shorter = min(bounds.width, bounds.height)
        let diameter = shorter * diameterFraction
        let padding = shorter * paddingFraction

        let x: CGFloat
        let y: CGFloat
        switch position {
        case .bottomRight:
            x = bounds.width - diameter - padding
            y = padding
        case .bottomLeft:
            x = padding
            y = padding
        case .topRight:
            x = bounds.width - diameter - padding
            y = bounds.height - diameter - padding
        case .topLeft:
            x = padding
            y = bounds.height - diameter - padding
        }
        return CGRect(x: x, y: y, width: diameter, height: diameter)
    }
}
