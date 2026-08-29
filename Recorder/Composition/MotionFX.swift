import CoreGraphics
import Foundation

struct SpringSettings: Equatable {
    /// Damping ratio. Values below 1 overshoot; closer to 1 settles faster.
    var dampingRatio: CGFloat
    /// Natural frequency in normalized time (`t` in 0...1).
    var response: CGFloat

    static let subtle = SpringSettings(dampingRatio: 0.85, response: 7)
    static let demo = SpringSettings(dampingRatio: 0.72, response: 8)
    static let punch = SpringSettings(dampingRatio: 0.62, response: 9)
}

struct MotionFXSettings: Equatable {
    var spring: SpringSettings
    var rippleRadius: CGFloat
    var rippleDuration: TimeInterval
    var secondRingDelay: TimeInterval
    var spotlightStrength: CGFloat
    var spotlightInnerRadius: CGFloat
    var spotlightOuterRadius: CGFloat
    var cursorClickDuration: TimeInterval
    var cursorPressedScale: CGFloat
    var cursorPopScale: CGFloat

    static let demo = MotionFXSettings(
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
}

enum SpringCamera {
    /// Underdamped step from 0 toward 1. May exceed 1 (overshoot), then settle.
    static func progress(
        elapsed: TimeInterval,
        duration: TimeInterval,
        settings: SpringSettings
    ) -> CGFloat {
        guard duration > 0 else { return 1 }
        let t = CGFloat(min(max(elapsed / duration, 0), 1))
        return underdampedStep(t: t, zeta: settings.dampingRatio, omega: settings.response)
    }

    static func interpolate(
        from: CGFloat,
        to: CGFloat,
        elapsed: TimeInterval,
        duration: TimeInterval,
        settings: SpringSettings
    ) -> CGFloat {
        from + (to - from) * progress(elapsed: elapsed, duration: duration, settings: settings)
    }

    static func interpolate(
        from: CGPoint,
        to: CGPoint,
        elapsed: TimeInterval,
        duration: TimeInterval,
        settings: SpringSettings
    ) -> CGPoint {
        CGPoint(
            x: interpolate(from: from.x, to: to.x, elapsed: elapsed, duration: duration, settings: settings),
            y: interpolate(from: from.y, to: to.y, elapsed: elapsed, duration: duration, settings: settings)
        )
    }

    static func underdampedStep(t: CGFloat, zeta: CGFloat, omega: CGFloat) -> CGFloat {
        let clampedZeta = min(0.999, max(0.05, zeta))
        let omegaSafe = max(omega, 0.01)
        let wd = omegaSafe * sqrt(1 - clampedZeta * clampedZeta)
        let decay = exp(-clampedZeta * omegaSafe * t)
        let coeff = clampedZeta / sqrt(1 - clampedZeta * clampedZeta)
        return 1 - decay * (cos(wd * t) + coeff * sin(wd * t))
    }
}

struct ClickRipple: Equatable {
    let location: CGPoint
    let progress: CGFloat
    let ring: Int
}

struct ClickRippleEvaluator: Equatable {
    var duration: TimeInterval
    var secondRingDelay: TimeInterval

    init(duration: TimeInterval = MotionFXSettings.demo.rippleDuration, secondRingDelay: TimeInterval = MotionFXSettings.demo.secondRingDelay) {
        self.duration = duration
        self.secondRingDelay = secondRingDelay
    }

    init(settings: MotionFXSettings) {
        self.duration = settings.rippleDuration
        self.secondRingDelay = settings.secondRingDelay
    }

    /// `0` at the click instant, `1` at `click + duration`, `nil` when idle.
    func progress(at time: TimeInterval, click: ClickEvent) -> CGFloat? {
        ringProgress(at: time, clickTime: click.timestamp, delay: 0)
    }

    func ripples(at time: TimeInterval, clicks: [ClickEvent]) -> [ClickRipple] {
        var result: [ClickRipple] = []
        for click in clicks {
            if let first = ringProgress(at: time, clickTime: click.timestamp, delay: 0) {
                result.append(ClickRipple(location: click.location, progress: first, ring: 0))
            }
            if let second = ringProgress(at: time, clickTime: click.timestamp, delay: secondRingDelay) {
                result.append(ClickRipple(location: click.location, progress: second, ring: 1))
            }
        }
        return result
    }

    private func ringProgress(at time: TimeInterval, clickTime: TimeInterval, delay: TimeInterval) -> CGFloat? {
        let start = clickTime + delay
        let end = start + duration
        if time < start || time > end {
            return nil
        }
        if duration <= 0 {
            return 1
        }
        return CGFloat((time - start) / duration)
    }
}

enum CursorClickScale {
    static func scale(
        at time: TimeInterval,
        clicks: [ClickEvent],
        settings: MotionFXSettings
    ) -> CGFloat {
        guard let click = nearestClick(at: time, clicks: clicks, duration: settings.cursorClickDuration) else {
            return 1
        }
        let elapsed = time - click.timestamp
        let duration = max(settings.cursorClickDuration, 0.001)
        let progress = min(max(elapsed / duration, 0), 1)
        let spring = SpringCamera.progress(
            elapsed: elapsed,
            duration: duration,
            settings: settings.spring
        )
        let pressed = settings.cursorPressedScale
        let pop = settings.cursorPopScale
        // Start at the pressed scale, spring toward 1, then use a short pop envelope.
        let recovered = pressed + (1 - pressed) * spring
        let popEnvelope = 4 * progress * (1 - progress)
        return recovered + (pop - 1) * popEnvelope * (1 - spring)
    }

    static func nearestClick(
        at time: TimeInterval,
        clicks: [ClickEvent],
        duration: TimeInterval
    ) -> ClickEvent? {
        clicks.last { click in
            time >= click.timestamp && time <= click.timestamp + duration
        }
    }
}
