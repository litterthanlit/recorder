import CoreGraphics
import Foundation

struct AutoZoomGenerator {
    let settings: AutoZoomSettings
    let frameWidth: CGFloat
    let frameHeight: CGFloat

    init(
        settings: AutoZoomSettings = AutoZoomSettings(),
        frameWidth: CGFloat,
        frameHeight: CGFloat
    ) {
        self.settings = settings
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
    }

    func generate(from events: [ClickEvent], duration: TimeInterval? = nil) -> [ZoomKeyframe] {
        guard !events.isEmpty, frameWidth > 0, frameHeight > 0, settings.zoomScale > 0 else { return [] }

        let mergedGroups = mergeEvents(events.sorted { $0.timestamp < $1.timestamp })
        var keyframes = mergedGroups.map { group in
            makeKeyframe(for: group, duration: duration)
        }

        ZoomKeyframeEditor.resolveOverlaps(&keyframes)
        return keyframes
    }

    private func mergeEvents(_ events: [ClickEvent]) -> [[ClickEvent]] {
        guard !events.isEmpty else { return [] }

        var groups: [[ClickEvent]] = [[events[0]]]

        for event in events.dropFirst() {
            if let lastTimestamp = groups.last?.last?.timestamp,
               event.timestamp - lastTimestamp <= settings.clickMergeWindow {
                groups[groups.count - 1].append(event)
            } else {
                groups.append([event])
            }
        }

        return groups
    }

    private func makeKeyframe(for group: [ClickEvent], duration: TimeInterval?) -> ZoomKeyframe {
        let rawPeak = group.map(\.timestamp).reduce(0, +) / Double(group.count)
        let peakTime = duration.map { min(max(0, rawPeak), $0) } ?? max(0, rawPeak)
        let center = normalizedCenter(for: group)

        let startTime = max(0, peakTime - settings.easeInDuration)
        let rawEnd = peakTime + settings.holdDuration + settings.easeOutDuration
        let endTime = duration.map { max(peakTime, min(rawEnd, $0)) } ?? rawEnd

        return ZoomKeyframe(
            startTime: startTime,
            peakTime: peakTime,
            endTime: endTime,
            center: center,
            scale: settings.zoomScale,
            source: .auto
        )
    }

    private func normalizedCenter(for group: [ClickEvent]) -> CGPoint {
        guard frameWidth > 0, frameHeight > 0, settings.zoomScale > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        let averageX = group.map(\.locationX).reduce(0, +) / CGFloat(group.count)
        let averageY = group.map(\.locationY).reduce(0, +) / CGFloat(group.count)

        let paddingScale = max(settings.cropPadding / frameWidth, settings.cropPadding / frameHeight)
        let normalized = CGPoint(
            x: averageX / frameWidth,
            y: averageY / frameHeight
        )

        let cropSize = min(1.0, 1.0 / settings.zoomScale)
        let minBound = min(0.5, cropSize / 2 + paddingScale)
        let maxBoundX = max(minBound, 1 - cropSize / 2 - paddingScale)
        let maxBoundY = max(minBound, 1 - cropSize / 2 - paddingScale)

        return CGPoint(
            x: clamp(normalized.x, min: minBound, max: maxBoundX),
            y: clamp(normalized.y, min: minBound, max: maxBoundY)
        )
    }

    private func clamp(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0.5 }
        return Swift.max(min, Swift.min(max, value))
    }
}
