import CoreGraphics
import Foundation

/// The shape of the exported video.
enum OutputAspect: String, Codable, CaseIterable, Identifiable {
    /// The recording's own shape.
    case auto
    case widescreen
    case standard
    case square
    case portrait
    case vertical

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .widescreen: return "16:9"
        case .standard: return "4:3"
        case .square: return "1:1"
        case .portrait: return "9:16"
        case .vertical: return "4:5"
        }
    }

    /// Where the shape is typically used, for the picker.
    var useCase: String {
        switch self {
        case .auto: return "Same shape as the recording"
        case .widescreen: return "YouTube, websites, presentations"
        case .standard: return "Classic slides"
        case .square: return "X, LinkedIn and Instagram feeds"
        case .portrait: return "Reels, TikTok, Shorts"
        case .vertical: return "Instagram and LinkedIn portrait"
        }
    }

    /// Width over height; `nil` for `.auto`.
    var ratio: CGFloat? {
        switch self {
        case .auto: return nil
        case .widescreen: return 16.0 / 9.0
        case .standard: return 4.0 / 3.0
        case .square: return 1
        case .portrait: return 9.0 / 16.0
        case .vertical: return 4.0 / 5.0
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = OutputAspect(rawValue: raw) ?? .auto
    }
}

/// The exported video's size, by its shorter side.
enum OutputResolution: String, Codable, CaseIterable, Identifiable {
    case hd720
    case hd1080
    case qhd1440
    case uhd2160
    /// As many pixels as the recording has.
    case source

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hd720: return "720p"
        case .hd1080: return "1080p"
        case .qhd1440: return "1440p"
        case .uhd2160: return "4K"
        case .source: return "Source"
        }
    }

    var shortSide: CGFloat? {
        switch self {
        case .hd720: return 720
        case .hd1080: return 1080
        case .qhd1440: return 1440
        case .uhd2160: return 2160
        case .source: return nil
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = OutputResolution(rawValue: raw) ?? .hd1080
    }
}

/// Shape and size of the exported video.
struct CanvasSpec: Codable, Equatable {
    var aspect: OutputAspect = .widescreen
    var resolution: OutputResolution = .hd1080
    /// When the picture has another shape: fill the canvas with a crop of its shape that
    /// follows the action (see `Reframer`) instead of fitting all of the picture on the
    /// background.
    var reframes = false

    init(aspect: OutputAspect = .widescreen, resolution: OutputResolution = .hd1080, reframes: Bool = false) {
        self.aspect = aspect
        self.resolution = resolution
        self.reframes = reframes
    }

    /// The pixel size for a recording of `source` pixels, with even dimensions.
    func pixelSize(source: CGSize) -> CGSize {
        let sourceAspect = source.width > 0 && source.height > 0 ? source.width / source.height : 16.0 / 9.0
        if aspect == .auto, resolution == .source {
            return CanvasLayout.even(source)
        }
        let ratio = aspect.ratio ?? sourceAspect
        let shortSide = resolution.shortSide ?? max(2, min(source.width, source.height))
        let size = ratio >= 1
            ? CGSize(width: shortSide * ratio, height: shortSide)
            : CGSize(width: shortSide, height: shortSide / ratio)
        return CanvasLayout.even(size)
    }

    /// The canvas for a project saved with the old resolution presets.
    static func migrated(from preset: ExportResolutionPreset) -> CanvasSpec {
        switch preset {
        case .source: return CanvasSpec(aspect: .auto, resolution: .source)
        case .hd1080p: return CanvasSpec(aspect: .widescreen, resolution: .hd1080)
        case .hd720p: return CanvasSpec(aspect: .widescreen, resolution: .hd720)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        aspect = try container.decodeIfPresent(OutputAspect.self, forKey: .aspect) ?? .widescreen
        resolution = try container.decodeIfPresent(OutputResolution.self, forKey: .resolution) ?? .hd1080
        reframes = (try? container.decodeIfPresent(Bool.self, forKey: .reframes)) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case aspect, resolution, reframes
    }
}

/// Layout of the output canvas, shared by export and the editor preview so they match
/// at any size.
enum CanvasLayout {
    /// Fixed-size details (corner radius, shadow, text) are designed at 1080 on the
    /// shorter side and scaled by this, so a 4K export or a small preview looks the same.
    static func referenceUnit(for canvas: CGSize) -> CGFloat {
        let shortSide = min(canvas.width, canvas.height)
        return shortSide > 0 ? shortSide / 1080 : 1
    }

    /// Space around the recording, as a fraction of the canvas's shorter side.
    static func padding(canvas: CGSize, ratio: CGFloat) -> CGFloat {
        min(canvas.width, canvas.height) * max(0, ratio)
    }

    /// Where the recording sits on the canvas: aspect-fit inside the padding, centred.
    static func contentFrame(canvas: CGSize, contentAspect: CGFloat, paddingRatio: CGFloat) -> CGRect {
        ZoomKeyframeEditor.fittedContentFrame(
            contentAspect: contentAspect,
            in: canvas,
            padding: padding(canvas: canvas, ratio: paddingRatio)
        )
    }

    /// Even dimensions (4:2:0 video needs them), at least 2.
    static func even(_ size: CGSize) -> CGSize {
        func even(_ value: CGFloat) -> CGFloat {
            guard value.isFinite, value > 0 else { return 2 }
            let rounded = Int(value.rounded())
            return CGFloat(max(2, rounded - rounded % 2))
        }
        return CGSize(width: even(size.width), height: even(size.height))
    }
}
