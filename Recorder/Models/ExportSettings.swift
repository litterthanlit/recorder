import CoreGraphics
import Foundation

enum ExportResolutionPreset: String, Codable, CaseIterable, Identifiable {
    case source
    case hd1080p
    case hd720p

    var id: String { rawValue }

    var label: String {
        switch self {
        case .source: return "Source"
        case .hd1080p: return "1080p"
        case .hd720p: return "720p"
        }
    }

    func outputSize(for source: CGSize) -> CGSize {
        switch self {
        case .source:
            return source
        case .hd1080p:
            return CGSize(width: 1920, height: 1080)
        case .hd720p:
            return CGSize(width: 1280, height: 720)
        }
    }

    /// Target bitrate for launch-friendly file sizes (~8MB at 60–90s for 1080p).
    var targetBitrate: Int {
        switch self {
        case .source:
            return 2_000_000
        case .hd1080p:
            return 700_000
        case .hd720p:
            return 450_000
        }
    }
}

enum ZoomPreset: String, Codable, CaseIterable, Identifiable {
    case subtle
    case demo
    case punch

    var id: String { rawValue }

    var label: String {
        switch self {
        case .subtle: return "Subtle"
        case .demo: return "Demo"
        case .punch: return "Punch"
        }
    }

    var settings: AutoZoomSettings {
        switch self {
        case .subtle:
            return AutoZoomSettings(
                zoomScale: 1.4,
                easeInDuration: 0.4,
                holdDuration: 1.5,
                easeOutDuration: 0.5,
                clickMergeWindow: 0.6,
                cropPadding: 80
            )
        case .demo:
            return AutoZoomSettings(
                zoomScale: 1.6,
                easeInDuration: 0.35,
                holdDuration: 1.3,
                easeOutDuration: 0.45,
                clickMergeWindow: 0.6,
                cropPadding: 80
            )
        case .punch:
            return AutoZoomSettings(
                zoomScale: 1.8,
                easeInDuration: 0.35,
                holdDuration: 1.2,
                easeOutDuration: 0.45,
                clickMergeWindow: 0.6,
                cropPadding: 80
            )
        }
    }
}

struct ExportStyle: Codable, Equatable {
    var backgroundEnabled: Bool = true
    var cornerRadius: CGFloat = 16
    var paddingFraction: CGFloat = 0.06
    var shadowEnabled: Bool = true
    var watermarkEnabled: Bool = false
    var watermarkText: String = "hypher.app"
    var cursorSmoothingEnabled: Bool = true

    static let runlyxDark = ExportStyle()
}

struct ProjectEditSettings: Codable, Equatable {
    var trimStart: TimeInterval = 0
    var trimEnd: TimeInterval?
    var exportPreset: ExportResolutionPreset = .hd1080p
    var exportStyle: ExportStyle = .runlyxDark
    var zoomPreset: ZoomPreset = .demo

    func effectiveTrimEnd(for duration: TimeInterval) -> TimeInterval {
        min(trimEnd ?? duration, duration)
    }

    func trimmedDuration(for fullDuration: TimeInterval) -> TimeInterval {
        max(0, effectiveTrimEnd(for: fullDuration) - trimStart)
    }
}

enum CaptureTargetKind: String, Codable, CaseIterable, Identifiable {
    case display
    case window

    var id: String { rawValue }

    var label: String {
        switch self {
        case .display: return "Full Display"
        case .window: return "Window"
        }
    }
}

struct CaptureWindowInfo: Codable, Equatable, Identifiable {
    let windowID: UInt32
    let title: String
    let appName: String

    var id: UInt32 { windowID }

    var displayName: String {
        if title.isEmpty {
            return appName
        }
        return "\(appName) — \(title)"
    }
}

struct RecordingPreferences: Codable, Equatable {
    var countdownSeconds: Int = 3
    var captureTarget: CaptureTargetKind = .display
    var selectedWindowID: UInt32?
    var hideChromeDuringRecording: Bool = true
    var cursorSmoothingEnabled: Bool = true
    var microphoneEnabled: Bool = false
    var selectedMicrophoneID: String?
    var cameraEnabled: Bool = false
    var selectedCameraID: String?
    var cameraPosition: CameraBubblePosition = .bottomRight
    var cameraBackground: CameraBackgroundMode = .none

    static let `default` = RecordingPreferences()
}
