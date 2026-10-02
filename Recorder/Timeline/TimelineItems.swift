import CoreGraphics
import Foundation

/// Text on top of the video (a title, a caption, a callout), timed in source time so it
/// stays with what's on screen when the edit changes.
struct TextOverlay: Codable, Equatable, Identifiable {
    enum Style: String, Codable, CaseIterable, Identifiable {
        /// Large bold text, no background.
        case title
        /// Medium text on a dark rounded plate.
        case caption
        /// Text on an accent-coloured pill.
        case callout

        var id: String { rawValue }

        var label: String {
            switch self {
            case .title: return "Title"
            case .caption: return "Caption"
            case .callout: return "Callout"
            }
        }

        /// Font size in points at 1080p.
        var baseFontSize: CGFloat {
            switch self {
            case .title: return 64
            case .caption: return 34
            case .callout: return 30
            }
        }

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Style(rawValue: raw) ?? .caption
        }
    }

    var id: UUID
    var text: String
    /// Source seconds.
    var span: TimeSpan
    /// Centre of the text on the canvas, normalized, top-left origin.
    var center: CGPoint
    var style: Style
    /// Size relative to the style's default.
    var scale: Double

    static let fadeDuration: TimeInterval = 0.2
    static let defaultDuration: TimeInterval = 3

    init(
        id: UUID = UUID(),
        text: String,
        span: TimeSpan,
        center: CGPoint = CGPoint(x: 0.5, y: 0.82),
        style: Style = .caption,
        scale: Double = 1
    ) {
        self.id = id
        self.text = text
        self.span = span
        self.center = center
        self.style = style
        self.scale = scale
    }

    /// 0 outside its span, fading in and out over `fadeDuration`.
    func opacity(at time: TimeInterval) -> Double {
        TimelineItemFade.opacity(at: time, span: span, fade: Self.fadeDuration)
    }

    /// `center` kept on the canvas (0–1 on both axes).
    static func clampedCenter(_ center: CGPoint) -> CGPoint {
        CGPoint(x: min(max(center.x, 0), 1), y: min(max(center.y, 0), 1))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        span = try container.decode(TimeSpan.self, forKey: .span)
        center = try container.decodeIfPresent(CGPoint.self, forKey: .center) ?? CGPoint(x: 0.5, y: 0.82)
        style = try container.decodeIfPresent(Style.self, forKey: .style) ?? .caption
        scale = try container.decodeIfPresent(Double.self, forKey: .scale) ?? 1
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, span, center, style, scale
    }
}

/// A part of the recording to hide (a password, an email address), blurred or pixelated
/// for a stretch of source time. It sits in source pixels, so it zooms with the content.
struct BlurRegion: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case blur
        case pixelate

        var id: String { rawValue }
        var label: String { self == .blur ? "Blur" : "Pixelate" }

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .blur
        }
    }

    var id: UUID
    /// Source seconds.
    var span: TimeSpan
    /// Normalized source rect, bottom-left origin (the same space as zoom centres).
    var rect: CGRect
    var kind: Kind
    /// 0 (light) to 1 (heavy).
    var strength: Double

    init(id: UUID = UUID(), span: TimeSpan, rect: CGRect, kind: Kind = .blur, strength: Double = 0.6) {
        self.id = id
        self.span = span
        self.rect = rect
        self.kind = kind
        self.strength = strength
    }

    func isActive(at time: TimeInterval) -> Bool {
        span.contains(time)
    }

    /// `rect` kept inside 0–1 and at least 2% across.
    static func clampedRect(_ rect: CGRect) -> CGRect {
        let width = min(max(rect.width, 0.02), 1)
        let height = min(max(rect.height, 0.02), 1)
        return CGRect(
            x: min(max(rect.minX, 0), 1 - width),
            y: min(max(rect.minY, 0), 1 - height),
            width: width,
            height: height
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        span = try container.decode(TimeSpan.self, forKey: .span)
        rect = try container.decode(CGRect.self, forKey: .rect)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .blur
        strength = try container.decodeIfPresent(Double.self, forKey: .strength) ?? 0.6
    }

    private enum CodingKeys: String, CodingKey {
        case id, span, rect, kind, strength
    }
}

enum TimelineItemFade {
    /// 1 inside `span`, ramping from 0 over `fade` at each end (shortened for short spans).
    static func opacity(at time: TimeInterval, span: TimeSpan, fade: TimeInterval) -> Double {
        guard span.duration > 0, time >= span.start, time <= span.end else { return 0 }
        let ramp = min(fade, span.duration / 2)
        guard ramp > 0 else { return 1 }
        let fromStart = (time - span.start) / ramp
        let toEnd = (span.end - time) / ramp
        return min(1, fromStart, toEnd)
    }
}

/// One keystroke pill on screen: a shortcut, or a run of typing.
struct KeystrokePill: Equatable {
    var text: String
    /// Source seconds.
    var span: TimeSpan
}

/// Turns recorded key presses into the pills the overlay shows: shortcuts get their own
/// pill (repeats become "⌘Z ×3"), typing runs merge into one pill, and a pill ends when
/// the next one starts.
enum KeystrokeOverlayTimeline {
    static let holdDuration: TimeInterval = 1.2
    static let typingMergeGap: TimeInterval = 0.8
    static let repeatGap: TimeInterval = 1.0
    static let maxTypingLength = 24

    static func pills(from events: [KeystrokeEvent], filter: KeystrokeFilter) -> [KeystrokePill] {
        var pills: [KeystrokePill] = []
        var lastKind: (isTyping: Bool, label: String, count: Int, lastTime: TimeInterval)?

        for event in events.sorted(by: { $0.timestamp < $1.timestamp }) where filter.includes(event) {
            let isTyping = !event.isShortcut
            let label = event.label
            let time = event.timestamp

            if let last = lastKind, var pill = pills.popLast() {
                if isTyping, last.isTyping, time - last.lastTime <= typingMergeGap {
                    pill.text = String((pill.text + label).suffix(maxTypingLength))
                    pill.span.end = time + holdDuration
                    pills.append(pill)
                    lastKind = (true, label, 1, time)
                    continue
                }
                if !isTyping, !last.isTyping, label == last.label, time - last.lastTime <= repeatGap {
                    let count = last.count + 1
                    pill.text = "\(label) ×\(count)"
                    pill.span.end = time + holdDuration
                    pills.append(pill)
                    lastKind = (false, label, count, time)
                    continue
                }
                // A new pill: the previous one gives way.
                pill.span.end = min(pill.span.end, time)
                pills.append(pill)
            }
            pills.append(KeystrokePill(text: label, span: TimeSpan(start: time, end: time + holdDuration)))
            lastKind = (isTyping, label, 1, time)
        }
        return pills.filter { $0.span.duration > 0 }
    }

    /// The pill showing at `time`, with its opacity (fading in and out quickly).
    static func pill(at time: TimeInterval, in pills: [KeystrokePill]) -> (pill: KeystrokePill, opacity: Double)? {
        guard let pill = pills.last(where: { $0.span.start <= time && time <= $0.span.end }) else { return nil }
        let opacity = TimelineItemFade.opacity(at: time, span: pill.span, fade: 0.12)
        return opacity > 0 ? (pill, opacity) : nil
    }
}
