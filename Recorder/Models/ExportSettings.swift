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

    var motionFX: MotionFXSettings {
        switch self {
        case .subtle:
            return MotionFXSettings(
                spring: .subtle,
                rippleRadius: 52,
                rippleDuration: 0.36,
                secondRingDelay: 0.08,
                spotlightStrength: 0.18,
                spotlightInnerRadius: 70,
                spotlightOuterRadius: 240,
                cursorClickDuration: 0.16,
                cursorPressedScale: 0.88,
                cursorPopScale: 1.08
            )
        case .demo:
            return MotionFXSettings(
                spring: .demo,
                rippleRadius: 72,
                rippleDuration: 0.42,
                secondRingDelay: 0.09,
                spotlightStrength: 0.28,
                spotlightInnerRadius: 80,
                spotlightOuterRadius: 280,
                cursorClickDuration: 0.18,
                cursorPressedScale: 0.82,
                cursorPopScale: 1.12
            )
        case .punch:
            return MotionFXSettings(
                spring: .punch,
                rippleRadius: 96,
                rippleDuration: 0.48,
                secondRingDelay: 0.1,
                spotlightStrength: 0.38,
                spotlightInnerRadius: 90,
                spotlightOuterRadius: 320,
                cursorClickDuration: 0.2,
                cursorPressedScale: 0.76,
                cursorPopScale: 1.18
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
    var springCameraEnabled: Bool = true
    var clickRipplesEnabled: Bool = true
    var cursorSpotlightEnabled: Bool = false
    var cursorScaleOnClickEnabled: Bool = true

    static let runlyxDark = ExportStyle()

    enum CodingKeys: String, CodingKey {
        case backgroundEnabled
        case cornerRadius
        case paddingFraction
        case shadowEnabled
        case watermarkEnabled
        case watermarkText
        case cursorSmoothingEnabled
        case springCameraEnabled
        case clickRipplesEnabled
        case cursorSpotlightEnabled
        case cursorScaleOnClickEnabled
    }

    init(
        backgroundEnabled: Bool = true,
        cornerRadius: CGFloat = 16,
        paddingFraction: CGFloat = 0.06,
        shadowEnabled: Bool = true,
        watermarkEnabled: Bool = false,
        watermarkText: String = "hypher.app",
        cursorSmoothingEnabled: Bool = true,
        springCameraEnabled: Bool = true,
        clickRipplesEnabled: Bool = true,
        cursorSpotlightEnabled: Bool = false,
        cursorScaleOnClickEnabled: Bool = true
    ) {
        self.backgroundEnabled = backgroundEnabled
        self.cornerRadius = cornerRadius
        self.paddingFraction = paddingFraction
        self.shadowEnabled = shadowEnabled
        self.watermarkEnabled = watermarkEnabled
        self.watermarkText = watermarkText
        self.cursorSmoothingEnabled = cursorSmoothingEnabled
        self.springCameraEnabled = springCameraEnabled
        self.clickRipplesEnabled = clickRipplesEnabled
        self.cursorSpotlightEnabled = cursorSpotlightEnabled
        self.cursorScaleOnClickEnabled = cursorScaleOnClickEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        backgroundEnabled = try container.decodeIfPresent(Bool.self, forKey: .backgroundEnabled) ?? true
        cornerRadius = try container.decodeIfPresent(CGFloat.self, forKey: .cornerRadius) ?? 16
        paddingFraction = try container.decodeIfPresent(CGFloat.self, forKey: .paddingFraction) ?? 0.06
        shadowEnabled = try container.decodeIfPresent(Bool.self, forKey: .shadowEnabled) ?? true
        watermarkEnabled = try container.decodeIfPresent(Bool.self, forKey: .watermarkEnabled) ?? false
        watermarkText = try container.decodeIfPresent(String.self, forKey: .watermarkText) ?? "hypher.app"
        cursorSmoothingEnabled = try container.decodeIfPresent(Bool.self, forKey: .cursorSmoothingEnabled) ?? true
        springCameraEnabled = try container.decodeIfPresent(Bool.self, forKey: .springCameraEnabled) ?? true
        clickRipplesEnabled = try container.decodeIfPresent(Bool.self, forKey: .clickRipplesEnabled) ?? true
        cursorSpotlightEnabled = try container.decodeIfPresent(Bool.self, forKey: .cursorSpotlightEnabled) ?? false
        cursorScaleOnClickEnabled = try container.decodeIfPresent(Bool.self, forKey: .cursorScaleOnClickEnabled) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(backgroundEnabled, forKey: .backgroundEnabled)
        try container.encode(cornerRadius, forKey: .cornerRadius)
        try container.encode(paddingFraction, forKey: .paddingFraction)
        try container.encode(shadowEnabled, forKey: .shadowEnabled)
        try container.encode(watermarkEnabled, forKey: .watermarkEnabled)
        try container.encode(watermarkText, forKey: .watermarkText)
        try container.encode(cursorSmoothingEnabled, forKey: .cursorSmoothingEnabled)
        try container.encode(springCameraEnabled, forKey: .springCameraEnabled)
        try container.encode(clickRipplesEnabled, forKey: .clickRipplesEnabled)
        try container.encode(cursorSpotlightEnabled, forKey: .cursorSpotlightEnabled)
        try container.encode(cursorScaleOnClickEnabled, forKey: .cursorScaleOnClickEnabled)
    }
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
