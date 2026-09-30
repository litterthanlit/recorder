import AppKit

/// Samples the system cursor's shape (arrow, I-beam, pointing hand) a few times a second
/// while recording, so the rendered cursor can change shape like the real one.
///
/// `NSCursor.currentSystem` returns a new object each time, so shapes are told apart by
/// where their hot spot sits relative to the image, which holds at any cursor size.
/// Anything else (resize arrows, custom cursors) is drawn as the arrow.
final class CursorKindSampler {
    private var timer: Timer?
    private let lock = NSLock()
    private var events: [CursorKindEvent] = []
    private var clock: RecordingClock?
    private lazy var references: [(CursorKind, CGPoint, CGFloat)] = [
        (.arrow, Self.features(of: NSCursor.arrow).hotSpot, Self.features(of: NSCursor.arrow).aspect),
        (.iBeam, Self.features(of: NSCursor.iBeam).hotSpot, Self.features(of: NSCursor.iBeam).aspect),
        (.pointingHand, Self.features(of: NSCursor.pointingHand).hotSpot, Self.features(of: NSCursor.pointingHand).aspect)
    ]

    func start(clock: RecordingClock) {
        stop()
        self.clock = clock
        lock.lock()
        events = []
        lock.unlock()
        let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            self?.sample()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @discardableResult
    func stop() -> [CursorKindEvent] {
        timer?.invalidate()
        timer = nil
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    private func sample() {
        guard let clock,
              let time = clock.recordingSeconds(forHostSeconds: CACurrentMediaTime()),
              let cursor = NSCursor.currentSystem
        else { return }
        let kind = classify(cursor)
        lock.lock()
        CursorKindTimeline.append(kind, at: time, to: &events)
        lock.unlock()
    }

    private func classify(_ cursor: NSCursor) -> CursorKind {
        let sample = Self.features(of: cursor)
        var best: (kind: CursorKind, distance: CGFloat) = (.arrow, .greatestFiniteMagnitude)
        for (kind, hotSpot, aspect) in references {
            let distance = hypot(sample.hotSpot.x - hotSpot.x, sample.hotSpot.y - hotSpot.y)
                + abs(sample.aspect - aspect) * 0.5
            if distance < best.distance {
                best = (kind, distance)
            }
        }
        return best.distance < 0.12 ? best.kind : .arrow
    }

    /// Hot spot as a fraction of the image size, and the image's width over height.
    private static func features(of cursor: NSCursor) -> (hotSpot: CGPoint, aspect: CGFloat) {
        let size = cursor.image.size
        guard size.width > 0, size.height > 0 else { return (.zero, 1) }
        return (
            CGPoint(x: cursor.hotSpot.x / size.width, y: cursor.hotSpot.y / size.height),
            size.width / size.height
        )
    }
}
