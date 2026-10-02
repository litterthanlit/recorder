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

    /// Bitrate for high-quality scene exports that will be edited and re-encoded later.
    ///
    /// Screen content with zooms changes every pixel during camera moves, so it needs far
    /// more than a size-capped delivery encode: ~0.08 bits per pixel per frame at 60 fps
    /// (≈10 Mbps at 1080p). Apply file-size limits to the final assembled video instead.
    func targetBitrate(for outputSize: CGSize, fps: Int = 60) -> Int {
        ExportBitrate.target(for: outputSize, fps: fps)
    }
}

enum ExportBitrate {
    /// ~0.08 bits per pixel per frame (≈10 Mbps at 1080p60): screen content with zooms
    /// changes every pixel during camera moves, so it needs more than a talking head.
    static func target(for outputSize: CGSize, fps: Int = 60, bitsPerPixelPerFrame: Double = 0.08) -> Int {
        let bitrate = Double(outputSize.width * outputSize.height) * Double(max(fps, 1)) * bitsPerPixelPerFrame
        return max(2_000_000, Int(bitrate.rounded()))
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

/// The look of the video: background and frame, cursor and clicks, keystrokes,
/// watermark. (The camera has its own `CameraOverlayStyle`.)
struct ExportStyle: Codable, Equatable {
    var background = BackgroundStyle()
    /// Corner radius of the recording, in points at 1080p (scaled with the canvas).
    var cornerRadius: CGFloat = 16
    /// Space around the recording, as a fraction of the canvas's shorter side.
    var paddingRatio: CGFloat = 0.1
    var shadowEnabled: Bool = true
    var watermarkEnabled: Bool = false
    var watermarkText: String = ""
    var cursorSmoothingEnabled: Bool = true
    var springCameraEnabled: Bool = true
    var clickRipplesEnabled: Bool = true
    var cursorSpotlightEnabled: Bool = false
    var cursorScaleOnClickEnabled: Bool = true
    /// Draw the recorded cursor at all.
    var showCursor: Bool = true
    /// Size relative to the real cursor.
    var cursorSize: Double = 1
    /// Fade the cursor out when the pointer rests.
    var hideIdleCursor: Bool = false
    var keystrokes = KeystrokeOverlayStyle()
    /// Blur the picture while the camera zooms and pans.
    var motionBlurEnabled: Bool = false

    static let cursorSizeRange: ClosedRange<Double> = 0.5...3
    static let runlyxDark = ExportStyle()

    /// Whether there's a frame around the recording (any background but none).
    var backgroundEnabled: Bool {
        get { background.kind != .none }
        set {
            if newValue {
                if background.kind == .none {
                    background.kind = .wallpaper
                }
            } else {
                background.kind = .none
            }
        }
    }

    init() {}

    enum CodingKeys: String, CodingKey {
        case background
        /// Before backgrounds had kinds: on (the dark gradient) or off. Still written.
        case backgroundEnabled
        case cornerRadius
        case paddingRatio
        /// Before canvases: a fraction of a 16:9 canvas's width.
        case paddingFraction
        case shadowEnabled
        case watermarkEnabled
        case watermarkText
        case cursorSmoothingEnabled
        case springCameraEnabled
        case clickRipplesEnabled
        case cursorSpotlightEnabled
        case cursorScaleOnClickEnabled
        case showCursor
        case cursorSize
        case hideIdleCursor
        case keystrokes
        case motionBlurEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ExportStyle()
        if let background = try? container.decodeIfPresent(BackgroundStyle.self, forKey: .background) {
            self.background = background
        } else if try container.decodeIfPresent(Bool.self, forKey: .backgroundEnabled) == false {
            background = BackgroundStyle(kind: .none)
        } else {
            background = BackgroundStyle(kind: .wallpaper, wallpaper: .midnight)
        }
        cornerRadius = try container.decodeIfPresent(CGFloat.self, forKey: .cornerRadius) ?? defaults.cornerRadius
        if let ratio = try container.decodeIfPresent(CGFloat.self, forKey: .paddingRatio) {
            paddingRatio = ratio
        } else if let fraction = try container.decodeIfPresent(CGFloat.self, forKey: .paddingFraction) {
            paddingRatio = fraction * 16 / 9
        } else {
            paddingRatio = defaults.paddingRatio
        }
        shadowEnabled = try container.decodeIfPresent(Bool.self, forKey: .shadowEnabled) ?? defaults.shadowEnabled
        watermarkEnabled = try container.decodeIfPresent(Bool.self, forKey: .watermarkEnabled) ?? defaults.watermarkEnabled
        watermarkText = try container.decodeIfPresent(String.self, forKey: .watermarkText) ?? defaults.watermarkText
        cursorSmoothingEnabled = try container.decodeIfPresent(Bool.self, forKey: .cursorSmoothingEnabled)
            ?? defaults.cursorSmoothingEnabled
        springCameraEnabled = try container.decodeIfPresent(Bool.self, forKey: .springCameraEnabled)
            ?? defaults.springCameraEnabled
        clickRipplesEnabled = try container.decodeIfPresent(Bool.self, forKey: .clickRipplesEnabled)
            ?? defaults.clickRipplesEnabled
        cursorSpotlightEnabled = try container.decodeIfPresent(Bool.self, forKey: .cursorSpotlightEnabled)
            ?? defaults.cursorSpotlightEnabled
        cursorScaleOnClickEnabled = try container.decodeIfPresent(Bool.self, forKey: .cursorScaleOnClickEnabled)
            ?? defaults.cursorScaleOnClickEnabled
        showCursor = try container.decodeIfPresent(Bool.self, forKey: .showCursor) ?? defaults.showCursor
        cursorSize = try container.decodeIfPresent(Double.self, forKey: .cursorSize) ?? defaults.cursorSize
        hideIdleCursor = try container.decodeIfPresent(Bool.self, forKey: .hideIdleCursor) ?? defaults.hideIdleCursor
        keystrokes = (try? container.decodeIfPresent(KeystrokeOverlayStyle.self, forKey: .keystrokes)) ?? defaults.keystrokes
        motionBlurEnabled = try container.decodeIfPresent(Bool.self, forKey: .motionBlurEnabled) ?? defaults.motionBlurEnabled
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(background, forKey: .background)
        try container.encode(backgroundEnabled, forKey: .backgroundEnabled)
        try container.encode(cornerRadius, forKey: .cornerRadius)
        try container.encode(paddingRatio, forKey: .paddingRatio)
        try container.encode(shadowEnabled, forKey: .shadowEnabled)
        try container.encode(watermarkEnabled, forKey: .watermarkEnabled)
        try container.encode(watermarkText, forKey: .watermarkText)
        try container.encode(cursorSmoothingEnabled, forKey: .cursorSmoothingEnabled)
        try container.encode(springCameraEnabled, forKey: .springCameraEnabled)
        try container.encode(clickRipplesEnabled, forKey: .clickRipplesEnabled)
        try container.encode(cursorSpotlightEnabled, forKey: .cursorSpotlightEnabled)
        try container.encode(cursorScaleOnClickEnabled, forKey: .cursorScaleOnClickEnabled)
        try container.encode(showCursor, forKey: .showCursor)
        try container.encode(cursorSize, forKey: .cursorSize)
        try container.encode(hideIdleCursor, forKey: .hideIdleCursor)
        try container.encode(keystrokes, forKey: .keystrokes)
        try container.encode(motionBlurEnabled, forKey: .motionBlurEnabled)
    }
}

/// How the separately recorded camera is shown in the composition.
struct CameraOverlayStyle: Codable, Equatable {
    var isVisible: Bool = true
    var position: CameraBubblePosition = .bottomRight
    var size: CameraBubbleSize = .medium
    /// Diameter as a fraction of the recording's shorter side, set by the size slider;
    /// `nil` uses `size`.
    var customSize: Double?
    var shape: CameraShape = .circle
    var borderEnabled: Bool = true

    static let sizeRange: ClosedRange<Double> = 0.08...0.4

    /// The diameter fraction to draw with.
    var diameterFraction: CGFloat {
        CGFloat(customSize.map { min(max($0, Self.sizeRange.lowerBound), Self.sizeRange.upperBound) } ?? Double(size.diameterFraction))
    }

    init(isVisible: Bool = true, position: CameraBubblePosition = .bottomRight, size: CameraBubbleSize = .medium) {
        self.isVisible = isVisible
        self.position = position
        self.size = size
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        position = try container.decodeIfPresent(CameraBubblePosition.self, forKey: .position) ?? .bottomRight
        size = try container.decodeIfPresent(CameraBubbleSize.self, forKey: .size) ?? .medium
        customSize = try container.decodeIfPresent(Double.self, forKey: .customSize)
        shape = try container.decodeIfPresent(CameraShape.self, forKey: .shape) ?? .circle
        borderEnabled = try container.decodeIfPresent(Bool.self, forKey: .borderEnabled) ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case isVisible
        case position
        case size
        case customSize
        case shape
        case borderEnabled
    }
}

/// What a recorded audio track holds.
enum AudioTrackRole: String, Codable, Equatable {
    case microphone
    case systemAudio

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AudioTrackRole(rawValue: raw) ?? .microphone
    }
}

/// Levels for the recorded audio tracks (1 is as recorded, 0 is muted).
struct AudioMixSettings: Codable, Equatable {
    static let volumeRange: ClosedRange<Double> = 0...2

    var microphoneVolume: Double = 1
    var systemAudioVolume: Double = 1
    /// Short fades either side of each cut, so the jump doesn't click.
    var cutFades = false
    /// Silence over parts played faster than 2.5×. See `AudioEnvelope`.
    var muteSpedUp = false

    func volume(for role: AudioTrackRole) -> Double {
        let volume = role == .microphone ? microphoneVolume : systemAudioVolume
        return min(max(volume, Self.volumeRange.lowerBound), Self.volumeRange.upperBound)
    }

    init(microphoneVolume: Double = 1, systemAudioVolume: Double = 1, cutFades: Bool = false, muteSpedUp: Bool = false) {
        self.microphoneVolume = microphoneVolume
        self.systemAudioVolume = systemAudioVolume
        self.cutFades = cutFades
        self.muteSpedUp = muteSpedUp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        microphoneVolume = try container.decodeIfPresent(Double.self, forKey: .microphoneVolume) ?? 1
        systemAudioVolume = try container.decodeIfPresent(Double.self, forKey: .systemAudioVolume) ?? 1
        cutFades = (try? container.decodeIfPresent(Bool.self, forKey: .cutFades)) ?? false
        muteSpedUp = (try? container.decodeIfPresent(Bool.self, forKey: .muteSpedUp)) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case microphoneVolume, systemAudioVolume, cutFades, muteSpedUp
    }
}

struct ProjectEditSettings: Codable, Equatable {
    /// Head and tail trim from before cuts existed. Still written (the outer edges of
    /// `timeline`) so an older build opening the project keeps the trim.
    var trimStart: TimeInterval = 0
    var trimEnd: TimeInterval?
    /// The edit (cuts, splits, speed). `nil` in projects from before it existed: see
    /// `resolvedTimeline(sourceDuration:)`.
    var timeline: EditTimeline?
    var audio = AudioMixSettings()
    /// Shape and size of the export.
    var canvas = CanvasSpec()
    var exportStyle: ExportStyle = .runlyxDark
    var zoomPreset: ZoomPreset = .demo
    var camera = CameraOverlayStyle()
    var textOverlays: [TextOverlay] = []
    var blurRegions: [BlurRegion] = []
    /// The part of the recording to show, like an app's window (normalized, bottom-left
    /// origin); `nil` shows all of it. See `SourceCrop`.
    var sourceCrop: CGRect?
    /// A transition at every cut; `nil` cuts straight.
    var cutTransition: CutTransition?

    /// The edit to use: the saved one, or the old trim as a single segment.
    func resolvedTimeline(sourceDuration: TimeInterval) -> EditTimeline {
        if let timeline {
            return timeline.normalized(sourceDuration: sourceDuration)
        }
        return EditTimeline.legacy(trimStart: trimStart, trimEnd: trimEnd, sourceDuration: sourceDuration)
    }

    /// Sets the edit and keeps the legacy trim fields in step with it.
    mutating func setTimeline(_ timeline: EditTimeline) {
        self.timeline = timeline
        trimStart = timeline.trimStart
        trimEnd = timeline.trimEnd
    }
}

enum CaptureTargetKind: String, Codable, CaseIterable, Identifiable {
    case display
    case window
    case area

    var id: String { rawValue }

    var label: String {
        switch self {
        case .display: return "Full Display"
        case .window: return "Window"
        case .area: return "Area"
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CaptureTargetKind(rawValue: raw) ?? .display
    }
}

struct CaptureDisplayInfo: Equatable, Identifiable {
    let displayID: UInt32
    let name: String

    var id: UInt32 { displayID }
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

/// Background treatment for the live camera (applied at record time).
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

struct RecordingPreferences: Codable, Equatable {
    var countdownSeconds: Int = 3
    var captureTarget: CaptureTargetKind = .display
    var selectedWindowID: UInt32?
    /// Display to record in `.display` mode; `nil` means the main display. Kept across
    /// launches (display IDs are stable), and resolved at record time in case it's gone.
    var selectedDisplayID: UInt32?
    var hideChromeDuringRecording: Bool = true
    var cursorSmoothingEnabled: Bool = true
    var microphoneEnabled: Bool = false
    var selectedMicrophoneID: String?
    var systemAudioEnabled: Bool = false
    var cameraEnabled: Bool = false
    var selectedCameraID: String?
    var cameraPosition: CameraBubblePosition = .bottomRight
    var cameraSize: CameraBubbleSize = .medium
    var cameraBackground: CameraBackgroundMode = .none
    /// The area recorded last in `.area` mode, offered again by the selector.
    var lastArea: CaptureArea?
    var areaPreset: AreaPreset = .free
    /// Capture frame rate (30 or 60).
    var frameRate: Int = 60
    /// Leave Finder's desktop icons out of display and area recordings.
    var hideDesktopIcons = false
    /// Leave notification banners out of display and area recordings.
    var hideNotifications = true
    /// Record key presses for the keystroke overlay (needs Input Monitoring).
    var recordKeystrokes = false

    static let `default` = RecordingPreferences()

    static let frameRateChoices = [30, 60]
}

// Decoding is tolerant so preferences saved by an older build still load after new
// fields are added. Defined in an extension to keep the memberwise initializer.
extension RecordingPreferences {
    private enum CodingKeys: String, CodingKey {
        case countdownSeconds
        case captureTarget
        case selectedWindowID
        case selectedDisplayID
        case hideChromeDuringRecording
        case cursorSmoothingEnabled
        case microphoneEnabled
        case selectedMicrophoneID
        case systemAudioEnabled
        case cameraEnabled
        case selectedCameraID
        case cameraPosition
        case cameraSize
        case cameraBackground
        case lastArea
        case areaPreset
        case frameRate
        case hideDesktopIcons
        case hideNotifications
        case recordKeystrokes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = RecordingPreferences()
        countdownSeconds = try container.decodeIfPresent(Int.self, forKey: .countdownSeconds) ?? defaults.countdownSeconds
        captureTarget = try container.decodeIfPresent(CaptureTargetKind.self, forKey: .captureTarget) ?? defaults.captureTarget
        selectedWindowID = try container.decodeIfPresent(UInt32.self, forKey: .selectedWindowID)
        selectedDisplayID = try container.decodeIfPresent(UInt32.self, forKey: .selectedDisplayID)
        hideChromeDuringRecording = try container.decodeIfPresent(Bool.self, forKey: .hideChromeDuringRecording)
            ?? defaults.hideChromeDuringRecording
        cursorSmoothingEnabled = try container.decodeIfPresent(Bool.self, forKey: .cursorSmoothingEnabled)
            ?? defaults.cursorSmoothingEnabled
        microphoneEnabled = try container.decodeIfPresent(Bool.self, forKey: .microphoneEnabled) ?? defaults.microphoneEnabled
        selectedMicrophoneID = try container.decodeIfPresent(String.self, forKey: .selectedMicrophoneID)
        systemAudioEnabled = try container.decodeIfPresent(Bool.self, forKey: .systemAudioEnabled)
            ?? defaults.systemAudioEnabled
        cameraEnabled = try container.decodeIfPresent(Bool.self, forKey: .cameraEnabled) ?? defaults.cameraEnabled
        selectedCameraID = try container.decodeIfPresent(String.self, forKey: .selectedCameraID)
        cameraPosition = try container.decodeIfPresent(CameraBubblePosition.self, forKey: .cameraPosition)
            ?? defaults.cameraPosition
        cameraSize = (try? container.decodeIfPresent(CameraBubbleSize.self, forKey: .cameraSize)) ?? defaults.cameraSize
        cameraBackground = (try? container.decodeIfPresent(CameraBackgroundMode.self, forKey: .cameraBackground))
            ?? defaults.cameraBackground
        lastArea = try? container.decodeIfPresent(CaptureArea.self, forKey: .lastArea)
        areaPreset = try container.decodeIfPresent(AreaPreset.self, forKey: .areaPreset) ?? defaults.areaPreset
        let savedFrameRate = try container.decodeIfPresent(Int.self, forKey: .frameRate) ?? defaults.frameRate
        frameRate = Self.frameRateChoices.contains(savedFrameRate) ? savedFrameRate : defaults.frameRate
        hideDesktopIcons = try container.decodeIfPresent(Bool.self, forKey: .hideDesktopIcons) ?? defaults.hideDesktopIcons
        hideNotifications = try container.decodeIfPresent(Bool.self, forKey: .hideNotifications)
            ?? defaults.hideNotifications
        recordKeystrokes = try container.decodeIfPresent(Bool.self, forKey: .recordKeystrokes) ?? defaults.recordKeystrokes
    }

    private static let defaultsKey = "recordingPreferences"

    /// Loads the last-used preferences. Window IDs don't survive relaunches, so the
    /// window selection is dropped.
    static func load(from defaults: UserDefaults = .standard) -> RecordingPreferences {
        guard let data = defaults.data(forKey: defaultsKey),
              var preferences = try? JSONDecoder().decode(RecordingPreferences.self, from: data)
        else {
            return .default
        }
        preferences.selectedWindowID = nil
        return preferences
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

// Tolerant decoding so settings.json written before a field existed still loads.
extension ProjectEditSettings {
    private enum CodingKeys: String, CodingKey {
        case trimStart
        case trimEnd
        case timeline
        case audio
        case canvas
        case exportStyle
        case zoomPreset
        case camera
        case textOverlays
        case blurRegions
        case sourceCrop
        case cutTransition
    }

    /// Keys only read, to migrate older settings.
    private enum LegacyKeys: String, CodingKey {
        /// Before canvases: source, 1080p or 720p.
        case exportPreset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ProjectEditSettings()
        trimStart = try container.decodeIfPresent(TimeInterval.self, forKey: .trimStart) ?? defaults.trimStart
        trimEnd = try container.decodeIfPresent(TimeInterval.self, forKey: .trimEnd)
        timeline = try? container.decodeIfPresent(EditTimeline.self, forKey: .timeline)
        audio = (try? container.decodeIfPresent(AudioMixSettings.self, forKey: .audio)) ?? defaults.audio
        if let canvas = try? container.decodeIfPresent(CanvasSpec.self, forKey: .canvas) {
            self.canvas = canvas
        } else if let preset = try? decoder.container(keyedBy: LegacyKeys.self)
            .decodeIfPresent(ExportResolutionPreset.self, forKey: .exportPreset) {
            canvas = CanvasSpec.migrated(from: preset)
        } else {
            canvas = defaults.canvas
        }
        exportStyle = try container.decodeIfPresent(ExportStyle.self, forKey: .exportStyle) ?? defaults.exportStyle
        zoomPreset = try container.decodeIfPresent(ZoomPreset.self, forKey: .zoomPreset) ?? defaults.zoomPreset
        camera = try container.decodeIfPresent(CameraOverlayStyle.self, forKey: .camera) ?? defaults.camera
        textOverlays = (try? container.decodeIfPresent([TextOverlay].self, forKey: .textOverlays)) ?? []
        blurRegions = (try? container.decodeIfPresent([BlurRegion].self, forKey: .blurRegions)) ?? []
        let crop = try? container.decodeIfPresent(CGRect.self, forKey: .sourceCrop)
        sourceCrop = crop.flatMap { SourceCrop.sanitized($0) }
        cutTransition = try? container.decodeIfPresent(CutTransition.self, forKey: .cutTransition)
    }
}
