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

/// Format, quality, frame rate and size limit of an export. (Its shape and size come
/// from the project's canvas.)
struct ExportOptions: Codable, Equatable {
    var format: ExportFormat = .mp4
    var quality: ExportQuality = .high
    /// `nil` exports at the recording's own frame rate.
    var frameRate: Int?
    /// Largest file an MP4 or HEVC export may make, in megabytes (1,000,000 bytes, as
    /// Finder counts them); `nil` for no limit. To fit, the bitrate drops, then the frame
    /// rate and the picture size.
    var maxMegabytes: Int?

    static let frameRateChoices = [24, 30, 60]
    static let sizeLimitChoices = [10, 25, 50, 100]
    static let gifFrameRate = 15
    /// GIFs get big quickly; they're scaled down to at most this wide.
    static let gifMaximumWidth: CGFloat = 720
    /// GIFs are for short loops; ImageIO keeps every frame until the file is written.
    static let gifMaximumDuration: TimeInterval = 30

    /// AAC bitrate of MP4 and HEVC exports, and of exports with a size limit.
    static let audioBitrate = 192_000
    static let limitedAudioBitrate = 128_000
    /// Uncompressed 16-bit stereo at 48 kHz, as ProRes exports carry it.
    static let pcmAudioBitrate = 1_536_000
    /// Share of a size limit the plan spends: the encoder's average bitrate can overshoot
    /// a little, and the MP4 container adds a few percent.
    static let sizeLimitHeadroom = 0.88
    /// Below this many bits per pixel per frame, text in a screen recording smears, so a
    /// smaller picture or a lower frame rate looks better than a starved one.
    static func minimumBitsPerPixelPerFrame(_ format: ExportFormat) -> Double {
        format == .hevc ? 0.02 : 0.03
    }
    /// Shorter sides tried, largest first, when an export has to shrink to fit.
    static let fitShortSides: [CGFloat] = [1080, 720, 540, 360]

    /// Whether `format` can export an edit `duration` seconds long.
    static func allows(_ format: ExportFormat, duration: TimeInterval) -> Bool {
        format != .gif || duration <= gifMaximumDuration + 0.001
    }

    init(format: ExportFormat = .mp4, quality: ExportQuality = .high, frameRate: Int? = nil, maxMegabytes: Int? = nil) {
        self.format = format
        self.quality = quality
        self.frameRate = frameRate
        self.maxMegabytes = maxMegabytes
    }

    /// Whether `maxMegabytes` applies to `format`.
    var usesSizeLimit: Bool {
        format.usesQuality
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

    /// Video bitrate for MP4 and HEVC at the chosen quality (HEVC needs about 70% of
    /// H.264 for the same look).
    func bitrate(size: CGSize, fps: Int) -> Int {
        let base = ExportBitrate.target(for: size, fps: fps, bitsPerPixelPerFrame: quality.bitsPerPixelPerFrame)
        return format == .hevc ? Int(Double(base) * 0.7) : base
    }

    /// Size, frame rate and bitrates of an export of a `canvas`-sized edit, `duration`
    /// seconds long, from a recording made at `sourceFrameRate` fps.
    func plan(canvas: CGSize, sourceFrameRate: Int, duration: TimeInterval) -> ExportPlan {
        let size = outputSize(canvas: canvas)
        let fps = outputFrameRate(source: sourceFrameRate)
        let seconds = max(duration, 0)
        switch format {
        case .gif:
            return ExportPlan(size: size, frameRate: fps, videoBitrate: 0, audioBitrate: 0, duration: seconds)
        case .prores:
            // ProRes 422 is about 5.3 bits per pixel per frame.
            let video = Int(Double(size.width * size.height) * Double(fps) * 5.3)
            return ExportPlan(size: size, frameRate: fps, videoBitrate: video, audioBitrate: Self.pcmAudioBitrate, duration: seconds)
        case .mp4, .hevc:
            guard let maxMegabytes, maxMegabytes > 0, seconds > 0 else {
                return ExportPlan(
                    size: size,
                    frameRate: fps,
                    videoBitrate: bitrate(size: size, fps: fps),
                    audioBitrate: Self.audioBitrate,
                    duration: seconds
                )
            }
            return fittedPlan(canvas: size, fps: fps, seconds: seconds, limitBytes: Int64(maxMegabytes) * 1_000_000)
        }
    }

    /// The largest size and frame rate whose picture still holds up within the limit,
    /// at the quality's bitrate or less.
    private func fittedPlan(canvas: CGSize, fps: Int, seconds: TimeInterval, limitBytes: Int64) -> ExportPlan {
        let audio = Self.limitedAudioBitrate
        let budget = Double(limitBytes) * 8 * Self.sizeLimitHeadroom / seconds - Double(audio)
        let minimum = Self.minimumBitsPerPixelPerFrame(format)
        let candidates = Self.fitCandidates(canvas: canvas, fps: fps)

        for candidate in candidates {
            let ceiling = Double(bitrate(size: candidate.size, fps: candidate.fps))
            let floor = Double(candidate.size.width * candidate.size.height) * Double(candidate.fps) * minimum
            guard budget >= floor else { continue }
            return ExportPlan(
                size: candidate.size,
                frameRate: candidate.fps,
                videoBitrate: Int(min(budget, ceiling)),
                audioBitrate: audio,
                duration: seconds,
                sizeLimitBytes: limitBytes
            )
        }

        // Too long for the limit even small: the smallest picture at its lowest quality,
        // flagged so the export sheet can say so.
        let smallest = candidates[candidates.count - 1]
        let floor = Double(smallest.size.width * smallest.size.height) * Double(smallest.fps) * minimum
        return ExportPlan(
            size: smallest.size,
            frameRate: smallest.fps,
            videoBitrate: Int(floor),
            audioBitrate: audio,
            duration: seconds,
            sizeLimitBytes: limitBytes
        )
    }

    /// Sizes and frame rates to try, best first: the canvas at the chosen frame rate, then
    /// at 30 fps, then each smaller standard size at 30 fps. Screen content reads better
    /// with sharp frames than with many of them.
    static func fitCandidates(canvas: CGSize, fps: Int) -> [(size: CGSize, fps: Int)] {
        let reducedRate = min(fps, 30)
        var candidates: [(size: CGSize, fps: Int)] = [(canvas, fps)]
        if reducedRate != fps {
            candidates.append((canvas, reducedRate))
        }
        let shortSide = min(canvas.width, canvas.height)
        guard shortSide > 0 else { return candidates }
        for side in fitShortSides where side < shortSide - 0.5 {
            let scale = side / shortSide
            let size = CanvasLayout.even(CGSize(width: canvas.width * scale, height: canvas.height * scale))
            candidates.append((size, reducedRate))
        }
        return candidates
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decodeIfPresent(ExportFormat.self, forKey: .format) ?? .mp4
        quality = try container.decodeIfPresent(ExportQuality.self, forKey: .quality) ?? .high
        let rate = try container.decodeIfPresent(Int.self, forKey: .frameRate)
        frameRate = rate.flatMap { Self.frameRateChoices.contains($0) ? $0 : nil }
        let limit = try container.decodeIfPresent(Int.self, forKey: .maxMegabytes)
        maxMegabytes = limit.flatMap { $0 > 0 ? $0 : nil }
    }

    private enum CodingKeys: String, CodingKey {
        case format, quality, frameRate, maxMegabytes
    }
}

/// What an export will be: decided once from `ExportOptions`, then followed by the
/// exporter and shown in the export sheet.
struct ExportPlan: Equatable {
    var size: CGSize
    var frameRate: Int
    /// Bits per second of the picture (0 for GIF, whose size depends on the content).
    var videoBitrate: Int
    var audioBitrate: Int
    var duration: TimeInterval
    /// The size limit the plan was fitted to, if any.
    var sizeLimitBytes: Int64?

    /// A rough file size in bytes; `nil` for GIF.
    var estimatedBytes: Int64? {
        guard videoBitrate > 0 else { return nil }
        return Int64(Double(videoBitrate + audioBitrate) * duration / 8)
    }

    /// The edit is too long to fit the size limit even at the smallest size.
    var exceedsSizeLimit: Bool {
        guard let sizeLimitBytes, let estimatedBytes else { return false }
        return estimatedBytes > sizeLimitBytes
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
