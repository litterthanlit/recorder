import CoreGraphics
import Foundation

enum MouseButton: String, Codable, Equatable {
    case left
    case right
}

struct ClickEvent: Codable, Equatable {
    let timestamp: TimeInterval
    let locationX: CGFloat
    let locationY: CGFloat
    let button: MouseButton

    var location: CGPoint {
        CGPoint(x: locationX, y: locationY)
    }

    init(timestamp: TimeInterval, location: CGPoint, button: MouseButton) {
        self.timestamp = timestamp
        self.locationX = location.x
        self.locationY = location.y
        self.button = button
    }
}
