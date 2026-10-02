import CoreGraphics
import Foundation

/// How a text overlay comes on and goes off.
enum TextAnimation: String, Codable, CaseIterable, Identifiable {
    /// Fades in and out (how text always behaved).
    case fade
    /// Rises into place as it fades in, and drifts up as it goes.
    case rise
    /// Springs up from smaller.
    case pop
    /// Comes into focus.
    case blur
    /// Types on character by character.
    case typewriter

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fade: return "Fade"
        case .rise: return "Rise"
        case .pop: return "Pop"
        case .blur: return "Focus"
        case .typewriter: return "Type"
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TextAnimation(rawValue: raw) ?? .fade
    }
}

/// A text overlay at one moment of its animation.
struct TextMotionState: Equatable {
    /// 0 is hidden, 1 solid.
    var opacity: Double
    /// Upward shift, in points at 1080p (scaled by `CanvasLayout.referenceUnit`).
    var rise: CGFloat = 0
    /// Size, 1 as laid out.
    var scale: CGFloat = 1
    /// Blur radius, in points at 1080p.
    var blur: CGFloat = 0
    /// How many characters are showing (typewriter); `nil` shows them all.
    var revealed: Int?

    static let hidden = TextMotionState(opacity: 0)

    var isVisible: Bool {
        opacity > 0.001 && revealed != 0
    }
}

/// Text animation over source time, so it stays with the recording through cuts and
/// speed changes, the same in preview and export.
enum TextMotion {
    /// The way in, and the way out (shorter for short text).
    static let entrance: TimeInterval = 0.5
    static let exit: TimeInterval = 0.3
    /// Typing speed; long text types faster so it's done by 60% of its time on screen.
    static let charactersPerSecond: Double = 28
    /// The pop's spring: quick, with a little overshoot.
    static let spring = SpringSettings(dampingRatio: 0.62, response: 9)

    static func state(for overlay: TextOverlay, at time: TimeInterval) -> TextMotionState {
        state(overlay.animation, span: overlay.span, characters: overlay.text.count, at: time)
    }

    static func state(_ animation: TextAnimation, span: TimeSpan, characters: Int, at time: TimeInterval) -> TextMotionState {
        guard animation != .fade else {
            return TextMotionState(opacity: TimelineItemFade.opacity(at: time, span: span, fade: TextOverlay.fadeDuration))
        }
        guard span.contains(time), span.duration > 0 else { return .hidden }

        let elapsed = time - span.start
        let remaining = span.end - time
        let entering = progress(elapsed, over: min(entrance, span.duration * 0.4))
        let leaving = progress(remaining, over: min(exit, span.duration * 0.3))
        let settled = easeOutCubic(entering)

        switch animation {
        case .fade:
            return .hidden
        case .rise:
            return TextMotionState(
                opacity: Double(min(entering / 0.6, 1) * leaving),
                rise: -28 * (1 - settled) + 10 * (1 - leaving)
            )
        case .pop:
            let spring = SpringCamera.progress(elapsed: elapsed, duration: min(entrance, span.duration * 0.4), settings: Self.spring)
            return TextMotionState(
                opacity: Double(min(entering / 0.35, 1) * leaving),
                scale: (0.82 + 0.18 * spring) * (0.94 + 0.06 * leaving)
            )
        case .blur:
            return TextMotionState(
                opacity: Double(settled * leaving),
                scale: 1 + 0.05 * (1 - settled),
                blur: 18 * (1 - settled) + 10 * (1 - leaving)
            )
        case .typewriter:
            let rate = max(charactersPerSecond, Double(characters) / max(span.duration * 0.6, 0.1))
            let typed = min(characters, Int(elapsed * rate) + 1)
            return TextMotionState(
                opacity: Double(progress(elapsed, over: 0.08) * leaving),
                revealed: max(typed, 0)
            )
        }
    }

    /// 0…1 across `duration` (1 at once for no duration).
    static func progress(_ elapsed: TimeInterval, over duration: TimeInterval) -> CGFloat {
        guard duration > 0 else { return 1 }
        return CGFloat(min(max(elapsed / duration, 0), 1))
    }

    static func easeOutCubic(_ value: CGFloat) -> CGFloat {
        let inverse = 1 - min(max(value, 0), 1)
        return 1 - inverse * inverse * inverse
    }
}
