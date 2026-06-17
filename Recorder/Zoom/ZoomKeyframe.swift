import CoreGraphics
import Foundation

enum ZoomSource: String, Codable, Equatable {
    case auto
    case manual
}

struct ZoomKeyframe: Codable, Equatable {
    let startTime: TimeInterval
    let peakTime: TimeInterval
    let endTime: TimeInterval
    let centerX: CGFloat
    let centerY: CGFloat
    let scale: CGFloat
    let source: ZoomSource

    var center: CGPoint {
        CGPoint(x: centerX, y: centerY)
    }

    init(
        startTime: TimeInterval,
        peakTime: TimeInterval,
        endTime: TimeInterval,
        center: CGPoint,
        scale: CGFloat,
        source: ZoomSource = .auto
    ) {
        self.startTime = startTime
        self.peakTime = peakTime
        self.endTime = endTime
        self.centerX = center.x
        self.centerY = center.y
        self.scale = scale
        self.source = source
    }
}

struct NormalizedRect: Equatable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    static let fullFrame = NormalizedRect(x: 0, y: 0, width: 1, height: 1)
}

struct AutoZoomSettings: Equatable {
    var zoomScale: CGFloat = 1.8
    var easeInDuration: TimeInterval = 0.35
    var holdDuration: TimeInterval = 1.2
    var easeOutDuration: TimeInterval = 0.45
    var clickMergeWindow: TimeInterval = 0.6
    var cropPadding: CGFloat = 80
}
