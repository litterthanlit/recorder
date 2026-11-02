import CoreGraphics
import Foundation

/// A colour stored as sRGB components, so styles stay Codable and free of AppKit.
struct RGBAColor: Codable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// From a hex string like "#6E56CF" or "6E56CF".
    init(hex: String, alpha: Double = 1) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt32(digits, radix: 16) ?? 0
        red = Double((value >> 16) & 0xFF) / 255
        green = Double((value >> 8) & 0xFF) / 255
        blue = Double(value & 0xFF) / 255
        self.alpha = alpha
    }

    var hexString: String {
        func component(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", component(red), component(green), component(blue))
    }

    /// Relative luminance (WCAG), for picking readable text over a background.
    var luminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    static let white = RGBAColor(red: 1, green: 1, blue: 1)
    static let black = RGBAColor(red: 0, green: 0, blue: 0)
}

/// A soft round glow in a wallpaper: full colour at its centre, fading to nothing at
/// `radius`.
struct WallpaperGlow: Equatable {
    /// Unit coordinates with a top-left origin; may lie outside 0…1 (a glow rising from
    /// below the frame).
    var center: CGPoint
    /// Where the glow has faded out, as a fraction of the canvas's longer side.
    var radius: CGFloat
    var color: RGBAColor
}

/// How a wallpaper is drawn: a 135° gradient, soft glows over it, and optionally fine
/// grain. The renderer and the inspector's swatches both draw from this.
struct WallpaperRecipe: Equatable {
    var start: RGBAColor
    var end: RGBAColor
    var glows: [WallpaperGlow]
    /// Strength of the grain, 0 (none) to 1. Grain hides banding in smooth gradients;
    /// exports with a size limit leave it out, since it costs bitrate.
    var grain: Double = 0
}

/// Ready-made backgrounds, drawn at render time (no image assets), so they're sharp at any
/// size: two-stop gradients with a glow, litt's soft washes, a mesh and an aura.
enum WallpaperPreset: String, Codable, CaseIterable, Identifiable {
    /// litt's ground: near-white with soft rose, blue and lime washes at the edges.
    case washes
    /// A mesh: violet, peach, pink and gold points blending, with fine grain.
    case dusk
    /// Near-black with one blue glow behind the recording.
    case aura
    case midnight
    case graphite
    case aurora
    case ocean
    case lavender
    case sunset
    case ember
    case forest
    case peach
    case candy
    case sky
    case snow

    var id: String { rawValue }

    var label: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }

    var recipe: WallpaperRecipe {
        switch self {
        case .washes:
            let ground = RGBAColor(hex: "FAFAFA")
            return WallpaperRecipe(start: ground, end: ground, glows: [
                WallpaperGlow(center: CGPoint(x: 0.08, y: 0), radius: 0.45, color: RGBAColor(hex: "FFAABE", alpha: 0.55)),
                WallpaperGlow(center: CGPoint(x: 1, y: 0.4), radius: 0.42, color: RGBAColor(hex: "8CBEFF", alpha: 0.5)),
                WallpaperGlow(center: CGPoint(x: 0.35, y: 1.15), radius: 0.4, color: RGBAColor(hex: "C2FF4D", alpha: 0.42))
            ])
        case .dusk:
            let ground = RGBAColor(hex: "2A1550")
            return WallpaperRecipe(start: ground, end: ground, glows: [
                WallpaperGlow(center: CGPoint(x: 0, y: 0.6), radius: 0.45, color: RGBAColor(hex: "6D28D9")),
                WallpaperGlow(center: CGPoint(x: 0.9, y: 0.1), radius: 0.4, color: RGBAColor(hex: "FF9466")),
                WallpaperGlow(center: CGPoint(x: 0.6, y: 1.1), radius: 0.36, color: RGBAColor(hex: "F472B6")),
                WallpaperGlow(center: CGPoint(x: 0.4, y: 0.1), radius: 0.22, color: RGBAColor(hex: "FBBF24"))
            ], grain: 0.5)
        case .aura:
            let ground = RGBAColor(hex: "05060C")
            return WallpaperRecipe(start: ground, end: ground, glows: [
                WallpaperGlow(center: CGPoint(x: 0.5, y: 0.58), radius: 0.45, color: RGBAColor(hex: "5078FF", alpha: 0.65))
            ])
        default:
            let colors = legacyColors
            return WallpaperRecipe(start: colors.start, end: colors.end, glows: [
                WallpaperGlow(center: CGPoint(x: 0.18, y: 0.1), radius: 0.75, color: colors.glow)
            ])
        }
    }

    /// Top-left and bottom-right colours, and the glow in the top-left corner, of the
    /// original two-stop wallpapers.
    private var legacyColors: (start: RGBAColor, end: RGBAColor, glow: RGBAColor) {
        switch self {
        case .midnight: return (RGBAColor(hex: "17171C"), RGBAColor(hex: "0A0A0F"), RGBAColor(hex: "2A2A38", alpha: 0.5))
        case .graphite: return (RGBAColor(hex: "3A3D45"), RGBAColor(hex: "15161A"), RGBAColor(hex: "5B5F6B", alpha: 0.35))
        case .aurora: return (RGBAColor(hex: "0F766E"), RGBAColor(hex: "4C1D95"), RGBAColor(hex: "34D399", alpha: 0.45))
        case .ocean: return (RGBAColor(hex: "1E3A8A"), RGBAColor(hex: "0891B2"), RGBAColor(hex: "60A5FA", alpha: 0.4))
        case .lavender: return (RGBAColor(hex: "8B7CF6"), RGBAColor(hex: "C4B5FD"), RGBAColor(hex: "F5F3FF", alpha: 0.45))
        case .sunset: return (RGBAColor(hex: "F97316"), RGBAColor(hex: "DB2777"), RGBAColor(hex: "FDE68A", alpha: 0.45))
        case .ember: return (RGBAColor(hex: "7F1D1D"), RGBAColor(hex: "EA580C"), RGBAColor(hex: "FCA5A5", alpha: 0.3))
        case .forest: return (RGBAColor(hex: "14532D"), RGBAColor(hex: "0D9488"), RGBAColor(hex: "86EFAC", alpha: 0.3))
        case .peach: return (RGBAColor(hex: "FDBA74"), RGBAColor(hex: "FB7185"), RGBAColor(hex: "FFF7ED", alpha: 0.5))
        case .candy: return (RGBAColor(hex: "EC4899"), RGBAColor(hex: "8B5CF6"), RGBAColor(hex: "FBCFE8", alpha: 0.4))
        case .sky: return (RGBAColor(hex: "BAE6FD"), RGBAColor(hex: "F0F9FF"), RGBAColor(hex: "FFFFFF", alpha: 0.6))
        case .snow, .washes, .dusk, .aura: return (RGBAColor(hex: "E5E7EB"), RGBAColor(hex: "F9FAFB"), RGBAColor(hex: "FFFFFF", alpha: 0.6))
        }
    }

    /// Whether text and overlays over it should be light. Judged on the ground the glows
    /// sit on.
    var isDark: Bool {
        let recipe = self.recipe
        return (recipe.start.luminance + recipe.end.luminance) / 2 < 0.35
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = WallpaperPreset(rawValue: raw) ?? .midnight
    }
}

enum BackgroundKind: String, Codable, CaseIterable, Identifiable {
    case wallpaper
    case gradient
    case solid
    case image
    /// No frame: the recording fills the canvas edge to edge.
    case none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .wallpaper: return "Wallpaper"
        case .gradient: return "Gradient"
        case .solid: return "Color"
        case .image: return "Image"
        case .none: return "None"
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BackgroundKind(rawValue: raw) ?? .wallpaper
    }
}

/// What's behind the recording.
struct BackgroundStyle: Codable, Equatable {
    var kind: BackgroundKind = .wallpaper
    var wallpaper: WallpaperPreset = .midnight
    var gradientStart = RGBAColor(hex: "6E56CF")
    var gradientEnd = RGBAColor(hex: "0EA5E9")
    /// Direction of the gradient in degrees; 135 runs from top-left to bottom-right.
    var gradientAngle: Double = 135
    var solidColor = RGBAColor(hex: "F4F4F5")
    /// An image copied into the project bundle (a file name inside it).
    var imageFileName: String?
    /// 0 (sharp) to 1 (very soft).
    var imageBlur: Double = 0

    /// The two colours the background is drawn with, for kinds that are gradients or a
    /// colour (a solid colour is a gradient between the same colour twice).
    var gradientColors: (start: RGBAColor, end: RGBAColor, glow: RGBAColor?) {
        switch kind {
        case .wallpaper:
            let recipe = wallpaper.recipe
            return (recipe.start, recipe.end, recipe.glows.first?.color)
        case .gradient:
            return (gradientStart, gradientEnd, nil)
        case .solid, .image, .none:
            return (solidColor, solidColor, nil)
        }
    }

    init(kind: BackgroundKind = .wallpaper, wallpaper: WallpaperPreset = .midnight) {
        self.kind = kind
        self.wallpaper = wallpaper
    }

    /// Where a gradient at `angle` starts and ends in `rect` (Core Image space, y up).
    /// Angles work like CSS `linear-gradient`: 0° runs bottom to top, 90° left to right,
    /// 135° top-left to bottom-right, and the colours reach the corners.
    static func gradientEndpoints(angle: Double, in rect: CGRect) -> (start: CGPoint, end: CGPoint) {
        let radians = angle * .pi / 180
        let dx = CGFloat(sin(radians))
        let dy = CGFloat(cos(radians))
        let length = abs(rect.width * dx) + abs(rect.height * dy)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return (
            CGPoint(x: center.x - dx * length / 2, y: center.y - dy * length / 2),
            CGPoint(x: center.x + dx * length / 2, y: center.y + dy * length / 2)
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BackgroundStyle()
        kind = try container.decodeIfPresent(BackgroundKind.self, forKey: .kind) ?? defaults.kind
        wallpaper = (try? container.decodeIfPresent(WallpaperPreset.self, forKey: .wallpaper)) ?? defaults.wallpaper
        gradientStart = try container.decodeIfPresent(RGBAColor.self, forKey: .gradientStart) ?? defaults.gradientStart
        gradientEnd = try container.decodeIfPresent(RGBAColor.self, forKey: .gradientEnd) ?? defaults.gradientEnd
        gradientAngle = try container.decodeIfPresent(Double.self, forKey: .gradientAngle) ?? defaults.gradientAngle
        solidColor = try container.decodeIfPresent(RGBAColor.self, forKey: .solidColor) ?? defaults.solidColor
        imageFileName = try container.decodeIfPresent(String.self, forKey: .imageFileName)
        imageBlur = try container.decodeIfPresent(Double.self, forKey: .imageBlur) ?? defaults.imageBlur
    }

    private enum CodingKeys: String, CodingKey {
        case kind, wallpaper, gradientStart, gradientEnd, gradientAngle, solidColor, imageFileName, imageBlur
    }
}

enum CameraShape: String, Codable, CaseIterable, Identifiable {
    case circle
    case roundedSquare

    var id: String { rawValue }

    var label: String {
        switch self {
        case .circle: return "Circle"
        case .roundedSquare: return "Rounded"
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CameraShape(rawValue: raw) ?? .circle
    }
}

/// Where and how big the keystroke overlay is.
struct KeystrokeOverlayStyle: Codable, Equatable {
    enum Placement: String, Codable, CaseIterable, Identifiable {
        case bottom
        case top

        var id: String { rawValue }
        var label: String { self == .bottom ? "Bottom" : "Top" }
    }

    var filter: KeystrokeFilter = .shortcuts
    var placement: Placement = .bottom
    /// Text size relative to the default.
    var scale: Double = 1

    init(filter: KeystrokeFilter = .shortcuts, placement: Placement = .bottom, scale: Double = 1) {
        self.filter = filter
        self.placement = placement
        self.scale = scale
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        filter = try container.decodeIfPresent(KeystrokeFilter.self, forKey: .filter) ?? .shortcuts
        placement = (try? container.decodeIfPresent(Placement.self, forKey: .placement)) ?? .bottom
        scale = try container.decodeIfPresent(Double.self, forKey: .scale) ?? 1
    }

    private enum CodingKeys: String, CodingKey {
        case filter, placement, scale
    }
}

/// When the smoothed cursor fades out because the pointer has been still.
enum CursorVisibility {
    /// When the pointer moved or clicked, sorted: each cursor sample more than `threshold`
    /// pixels from the last one that counted, and every click.
    static func activityTimes(cursor: [CursorEvent], clicks: [ClickEvent], threshold: CGFloat = 1) -> [TimeInterval] {
        var times: [TimeInterval] = []
        var anchor: CGPoint?
        for event in cursor.sorted(by: { $0.timestamp < $1.timestamp }) {
            if let anchor, hypot(event.locationX - anchor.x, event.locationY - anchor.y) <= threshold {
                continue
            }
            times.append(event.timestamp)
            anchor = event.location
        }
        times.append(contentsOf: clicks.map(\.timestamp))
        return times.sorted()
    }

    /// Opacity of the cursor at `time` (source seconds), given its samples sorted by time.
    /// With `hideWhenIdle`, it fades out after `idleDelay` seconds without movement or a
    /// click and fades back in just before it next moves.
    static func opacity(
        at time: TimeInterval,
        activity: [TimeInterval],
        hideWhenIdle: Bool,
        idleDelay: TimeInterval = 1.5,
        fade: TimeInterval = 0.25
    ) -> Double {
        guard hideWhenIdle, !activity.isEmpty else { return 1 }
        // Latest activity at or before `time`, and the next one after it.
        var low = 0
        var high = activity.count
        while low < high {
            let mid = (low + high) / 2
            if activity[mid] <= time {
                low = mid + 1
            } else {
                high = mid
            }
        }
        let previous = low > 0 ? activity[low - 1] : nil
        let next = low < activity.count ? activity[low] : nil

        var opacity = 0.0
        if let previous {
            let idle = time - previous
            opacity = max(opacity, idle <= idleDelay ? 1 : max(0, 1 - (idle - idleDelay) / fade))
        }
        if let next {
            let until = next - time
            opacity = max(opacity, until <= fade ? 1 - until / fade : 0)
        }
        return min(max(opacity, 0), 1)
    }
}
