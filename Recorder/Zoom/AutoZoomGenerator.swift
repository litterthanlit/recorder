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

    func generate(from events: [ClickEvent]) -> [ZoomKeyframe] {
        guard !events.isEmpty else { return [] }

        let mergedGroups = mergeEvents(events.sorted { $0.timestamp < $1.timestamp })
        var keyframes = mergedGroups.map { group in
            makeKeyframe(for: group)
        }

        resolveOverlaps(&keyframes)
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

    private func makeKeyframe(for group: [ClickEvent]) -> ZoomKeyframe {
        let peakTime = group.map(\.timestamp).reduce(0, +) / Double(group.count)
        let center = normalizedCenter(for: group)

        let startTime = max(0, peakTime - settings.easeInDuration)
        let endTime = peakTime + settings.holdDuration + settings.easeOutDuration

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
        let averageX = group.map(\.locationX).reduce(0, +) / CGFloat(group.count)
        let averageY = group.map(\.locationY).reduce(0, +) / CGFloat(group.count)

        let paddingScale = max(settings.cropPadding / frameWidth, settings.cropPadding / frameHeight)
        let normalized = CGPoint(
            x: averageX / frameWidth,
            y: averageY / frameHeight
        )

        let cropSize = 1.0 / settings.zoomScale
        let minBound = cropSize / 2 + paddingScale
        let maxBoundX = 1 - cropSize / 2 - paddingScale
        let maxBoundY = 1 - cropSize / 2 - paddingScale

        return CGPoint(
            x: clamp(normalized.x, min: minBound, max: max( minBound, maxBoundX)),
            y: clamp(normalized.y, min: minBound, max: max(minBound, maxBoundY))
        )
    }

    private func resolveOverlaps(_ keyframes: inout [ZoomKeyframe]) {
        guard keyframes.count > 1 else { return }

        keyframes.sort { $0.startTime < $1.startTime }

        for index in 1..<keyframes.count {
            let previous = keyframes[index - 1]
            var current = keyframes[index]

            if current.startTime < previous.endTime {
                let shiftedStart = previous.endTime
                let duration = current.endTime - current.startTime
                let peakOffset = current.peakTime - current.startTime

                current = ZoomKeyframe(
                    startTime: shiftedStart,
                    peakTime: shiftedStart + peakOffset,
                    endTime: shiftedStart + duration,
                    center: current.center,
                    scale: current.scale,
                    source: current.source
                )
                keyframes[index] = current
            }
        }
    }

    private func clamp(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        Swift.max(min, Swift.min(max, value))
    }
}
