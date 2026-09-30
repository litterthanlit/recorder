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

/// Ready-made backgrounds: two-stop gradients with a soft glow, drawn at render time (no
/// image assets), so they're sharp at any size.
enum WallpaperPreset: String, Codable, CaseIterable, Identifiable {
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

    /// Top-left and bottom-right colours, and the glow in the top-left corner.
    var colors: (start: RGBAColor, end: RGBAColor, glow: RGBAColor) {
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
        case .snow: return (RGBAColor(hex: "E5E7EB"), RGBAColor(hex: "F9FAFB"), RGBAColor(hex: "FFFFFF", alpha: 0.6))
        }
    }

    var isDark: Bool {
        let colors = self.colors
        return (colors.start.luminance + colors.end.luminance) / 2 < 0.35
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
            let colors = wallpaper.colors
            return (colors.start, colors.end, colors.glow)
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
