import CoreGraphics
import Foundation

/// The kind of file an export makes.
enum ExportFormat: String, Codable, CaseIterable, Identifiable {
    /// H.264 in MP4 (HEVC when the frame is too big for H.264).
    case mp4
    case hevc
    /// ProRes 422 in a QuickTime movie, with uncompressed audio.
    case prores
    case gif

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mp4: return "MP4"
        case .hevc: return "HEVC"
        case .prores: return "ProRes"
        case .gif: return "GIF"
        }
    }

    var detail: String {
        switch self {
        case .mp4: return "Plays everywhere"
        case .hevc: return "Smaller files, recent devices"
        case .prores: return "For Final Cut, Premiere, Resolve"
        case .gif: return "Loops in docs, chats and READMEs"
        }
    }

    var fileExtension: String {
        switch self {
        case .mp4, .hevc: return "mp4"
        case .prores: return "mov"
        case .gif: return "gif"
        }
    }

    var hasAudio: Bool {
        self != .gif
    }

    /// Whether the quality setting (bitrate) applies.
    var usesQuality: Bool {
        self == .mp4 || self == .hevc
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ExportFormat(rawValue: raw) ?? .mp4
    }
}

/// How much data a compressed export spends on the picture.
enum ExportQuality: String, Codable, CaseIterable, Identifiable {
    /// Small files for the web and chat.
    case web
    case high
    /// Near-lossless, for further editing.
    case studio

    var id: String { rawValue }

    var label: String {
        switch self {
        case .web: return "Web"
        case .high: return "High"
        case .studio: return "Studio"
        }
    }

    /// Bits per pixel per frame. Screen content with zooms changes every pixel during
    /// camera moves, so even "web" is generous next to a talking head.
    var bitsPerPixelPerFrame: Double {
        switch self {
        case .web: return 0.045
        case .high: return 0.08
        case .studio: return 0.16
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ExportQuality(rawValue: raw) ?? .high
    }
}

/// Format, quality and frame rate of an export. (Its shape and size come from the
/// project's canvas.)
struct ExportOptions: Codable, Equatable {
    var format: ExportFormat = .mp4
    var quality: ExportQuality = .high
    /// `nil` exports at the recording's own frame rate.
    var frameRate: Int?

    static let frameRateChoices = [24, 30, 60]
    static let gifFrameRate = 15
    /// GIFs get big quickly; they're scaled down to at most this wide.
    static let gifMaximumWidth: CGFloat = 720
    /// GIFs are for short loops; ImageIO keeps every frame until the file is written.
    static let gifMaximumDuration: TimeInterval = 30

    /// Whether `format` can export an edit `duration` seconds long.
    static func allows(_ format: ExportFormat, duration: TimeInterval) -> Bool {
        format != .gif || duration <= gifMaximumDuration + 0.001
    }

    init(format: ExportFormat = .mp4, quality: ExportQuality = .high, frameRate: Int? = nil) {
        self.format = format
        self.quality = quality
        self.frameRate = frameRate
    }

    /// Frames per second of the export for a recording made at `source` fps.
    func outputFrameRate(source: Int) -> Int {
        if format == .gif {
            return Self.gifFrameRate
        }
        if let frameRate, Self.frameRateChoices.contains(frameRate) {
            return frameRate
        }
        return max(1, source)
    }

    /// Pixel size of the export for a canvas of `canvas` pixels (GIFs are scaled down).
    func outputSize(canvas: CGSize) -> CGSize {
        guard format == .gif, canvas.width > Self.gifMaximumWidth, canvas.width > 0 else {
            return canvas
        }
        let scale = Self.gifMaximumWidth / canvas.width
        return CanvasLayout.even(CGSize(width: canvas.width * scale, height: canvas.height * scale))
    }

    /// Video bitrate for MP4 and HEVC (HEVC needs about 70% of H.264 for the same look).
    func bitrate(size: CGSize, fps: Int) -> Int {
        let base = ExportBitrate.target(for: size, fps: fps, bitsPerPixelPerFrame: quality.bitsPerPixelPerFrame)
        return format == .hevc ? Int(Double(base) * 0.7) : base
    }

    /// A rough file size in bytes, for the export sheet; `nil` when it can't be guessed
    /// (GIF size depends on the content).
    func estimatedBytes(size: CGSize, fps: Int, duration: TimeInterval) -> Int64? {
        let seconds = max(duration, 0)
        switch format {
        case .mp4, .hevc:
            let bits = Double(bitrate(size: size, fps: fps)) * seconds + 192_000 * seconds
            return Int64(bits / 8)
        case .prores:
            // ProRes 422 is about 5.3 bits per pixel per frame, plus 16-bit stereo audio.
            let bits = Double(size.width * size.height) * Double(fps) * 5.3 * seconds + 1_536_000 * seconds
            return Int64(bits / 8)
        case .gif:
            return nil
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decodeIfPresent(ExportFormat.self, forKey: .format) ?? .mp4
        quality = try container.decodeIfPresent(ExportQuality.self, forKey: .quality) ?? .high
        let rate = try container.decodeIfPresent(Int.self, forKey: .frameRate)
        frameRate = rate.flatMap { Self.frameRateChoices.contains($0) ? $0 : nil }
    }

    private enum CodingKeys: String, CodingKey {
        case format, quality, frameRate
    }
}

/// Export choices remembered between exports.
struct ExportPreferences: Codable, Equatable {
    var options = ExportOptions()
    /// Show a save panel for every export instead of using `folderPath`.
    var askForLocation = false
    /// Where exports go; `nil` is `~/Movies/Trace/Exports`.
    var folderPath: String?
    /// File name, with `{name}`, `{date}` and `{time}` filled in.
    var fileNameTemplate = ExportNaming.defaultTemplate
    /// Show the file in Finder when an export finishes.
    var revealWhenDone = false

    init() {}

    var folderURL: URL {
        folderPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? ProjectStore.exportsDirectory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        options = (try? container.decodeIfPresent(ExportOptions.self, forKey: .options)) ?? ExportOptions()
        askForLocation = try container.decodeIfPresent(Bool.self, forKey: .askForLocation) ?? false
        folderPath = try container.decodeIfPresent(String.self, forKey: .folderPath)
        fileNameTemplate = try container.decodeIfPresent(String.self, forKey: .fileNameTemplate) ?? ExportNaming.defaultTemplate
        revealWhenDone = try container.decodeIfPresent(Bool.self, forKey: .revealWhenDone) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case options, askForLocation, folderPath, fileNameTemplate, revealWhenDone
    }

    private static let defaultsKey = "exportPreferences"

    static func load(from defaults: UserDefaults = .standard) -> ExportPreferences {
        guard let data = defaults.data(forKey: defaultsKey),
              let preferences = try? JSONDecoder().decode(ExportPreferences.self, from: data)
        else { return ExportPreferences() }
        return preferences
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// File names for exports.
enum ExportNaming {
    static let defaultTemplate = "{name}"

    /// The template with `{name}`, `{date}` (2026-09-30) and `{time}` (14.05.09) filled
    /// in, made safe for a file name, plus the extension.
    static func fileName(template: String, name: String, date: Date, fileExtension: String, calendar: Calendar = .current) -> String {
        baseName(template: template, name: name, date: date, calendar: calendar) + "." + fileExtension
    }

    /// The file name without its extension.
    static func baseName(template: String, name: String, date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let dateText = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let timeText = String(format: "%02d.%02d.%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        let filled = template
            .replacingOccurrences(of: "{name}", with: name)
            .replacingOccurrences(of: "{date}", with: dateText)
            .replacingOccurrences(of: "{time}", with: timeText)
        return sanitized(filled)
    }

    /// Without characters Finder and other systems reject (/ : and control characters),
    /// a leading dot, or runs of spaces; at most 120 characters. Never empty.
    static func sanitized(_ name: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/:\\").union(.controlCharacters).union(.newlines)
        var scalars = String.UnicodeScalarView()
        let space: Unicode.Scalar = " "
        for scalar in name.unicodeScalars {
            scalars.append(disallowed.contains(scalar) ? space : scalar)
        }
        var cleaned = String(scalars)
        while cleaned.contains("  ") {
            cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") {
            cleaned.removeFirst()
        }
        cleaned = String(cleaned.prefix(120)).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Recording" : cleaned
    }

    /// `fileName` in `folder`, or "Name 2.mp4", "Name 3.mp4"… if it's taken.
    static func uniqueURL(in folder: URL, fileName: String, exists: (URL) -> Bool) -> URL {
        let candidate = folder.appendingPathComponent(fileName)
        guard exists(candidate) else { return candidate }
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var number = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            let url = folder.appendingPathComponent(name)
            if !exists(url) {
                return url
            }
            number += 1
        }
    }
}

/// GIF frame timing. GIF delays are whole hundredths of a second, so a frame rate that
/// doesn't divide 100 is approximated by mixing delays, keeping the total in step.
enum GIFTiming {
    /// Delays in hundredths of a second for `frameCount` frames at `fps`.
    static func delays(frameCount: Int, fps: Int) -> [Int] {
        guard frameCount > 0 else { return [] }
        let rate = Double(max(fps, 1))
        return (0..<frameCount).map { index in
            let start = (Double(index) * 100 / rate).rounded()
            let end = (Double(index + 1) * 100 / rate).rounded()
            // Browsers treat delays under 2 as 10, so never go below 2.
            return max(2, Int(end - start))
        }
    }
}

/// Where a project's latest export went (exports.json in the bundle).
struct ExportRecord: Codable, Equatable {
    var path: String
    var format: ExportFormat
    var date: Date

    var url: URL {
        URL(fileURLWithPath: path)
    }
}
