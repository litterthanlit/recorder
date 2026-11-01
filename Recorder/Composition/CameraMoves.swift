import CoreGraphics
import Foundation

/// A 3D move of the recording's frame, like a camera moving around a screen in space.
enum CameraMoveKind: String, Codable, CaseIterable, Identifiable {
    /// Starts tilted back in perspective and settles flat: an opening.
    case tiltIn = "tilt_in"
    /// Tilts away at the end: a closing.
    case tiltOut = "tilt_out"
    /// Hovers, turning gently.
    case float
    /// Swings slowly from one side to the other.
    case orbit
    /// Moves slowly closer.
    case pushIn = "push_in"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tiltIn: return "Tilt In"
        case .tiltOut: return "Tilt Out"
        case .float: return "Float"
        case .orbit: return "Orbit"
        case .pushIn: return "Push In"
        }
    }

    /// How long a new move of this kind lasts.
    var defaultDuration: TimeInterval {
        switch self {
        case .tiltIn, .tiltOut: return 1.4
        case .float, .orbit: return 4
        case .pushIn: return 3
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CameraMoveKind(rawValue: raw) ?? .float
    }
}

/// A 3D move over a stretch of the recording (source time), so it stays with what's on
/// screen through cuts.
struct CameraMove: Codable, Equatable, Identifiable {
    var id: UUID
    var kind: CameraMoveKind
    var span: TimeSpan
    /// How strong, 0–1.
    var intensity: Double

    static let defaultIntensity = 0.6

    init(id: UUID = UUID(), kind: CameraMoveKind, span: TimeSpan, intensity: Double = CameraMove.defaultIntensity) {
        self.id = id
        self.kind = kind
        self.span = span
        self.intensity = min(max(intensity.isFinite ? intensity : Self.defaultIntensity, 0), 1)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            kind: (try? container.decodeIfPresent(CameraMoveKind.self, forKey: .kind)) ?? .float,
            span: try container.decode(TimeSpan.self, forKey: .span),
            intensity: (try? container.decodeIfPresent(Double.self, forKey: .intensity)) ?? Self.defaultIntensity
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, span, intensity
    }
}

/// A tilt, turn, roll, size and shift of the recording's frame.
struct ScreenTransform3D: Equatable {
    /// Radians. Positive brings the top toward the viewer.
    var rotationX: Double = 0
    /// Radians. Positive takes the right side away.
    var rotationY: Double = 0
    /// Radians, counterclockwise.
    var rotationZ: Double = 0
    var scale: Double = 1
    /// Shift in points at 1080p (`CanvasLayout.referenceUnit` scales it), y up.
    var shiftX: Double = 0
    var shiftY: Double = 0

    static let identity = ScreenTransform3D()

    var isIdentity: Bool {
        self == .identity
    }

    /// `self` moved toward `other` by `amount` (0 is `self`, 1 is `other`).
    func mixed(with other: ScreenTransform3D, _ amount: Double) -> ScreenTransform3D {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * amount }
        return ScreenTransform3D(
            rotationX: mix(rotationX, other.rotationX),
            rotationY: mix(rotationY, other.rotationY),
            rotationZ: mix(rotationZ, other.rotationZ),
            scale: mix(scale, other.scale),
            shiftX: mix(shiftX, other.shiftX),
            shiftY: mix(shiftY, other.shiftY)
        )
    }

    /// Both at once (overlapping moves).
    func combined(with other: ScreenTransform3D) -> ScreenTransform3D {
        ScreenTransform3D(
            rotationX: rotationX + other.rotationX,
            rotationY: rotationY + other.rotationY,
            rotationZ: rotationZ + other.rotationZ,
            scale: scale * other.scale,
            shiftX: shiftX + other.shiftX,
            shiftY: shiftY + other.shiftY
        )
    }
}

/// The camera moves over source time.
enum CameraMoves {
    /// Moves ease in and out over this long (float, orbit and push in).
    static let edge: TimeInterval = 0.6
    /// Tilt in settles like a camera on a spring.
    static let settle = SpringSettings(dampingRatio: 0.8, response: 7)

    /// The frame's transform at source time `time`: identity outside every move.
    static func transform(at time: TimeInterval, moves: [CameraMove]) -> ScreenTransform3D {
        var result = ScreenTransform3D.identity
        for move in moves where move.span.contains(time) && move.span.duration > 0 {
            result = result.combined(with: transform(of: move, at: time))
        }
        return result
    }

    static func transform(of move: CameraMove, at time: TimeInterval) -> ScreenTransform3D {
        let strength = min(max(move.intensity, 0), 1)
        let elapsed = time - move.span.start
        let progress = min(max(elapsed / move.span.duration, 0), 1)
        func degrees(_ value: Double) -> Double { value * strength * .pi / 180 }

        switch move.kind {
        case .tiltIn:
            let tilted = ScreenTransform3D(
                rotationX: degrees(-24),
                rotationY: degrees(16),
                rotationZ: degrees(-2),
                scale: 1 - 0.16 * strength,
                shiftY: -30 * strength
            )
            let settled = SpringCamera.progress(elapsed: elapsed, duration: move.span.duration, settings: settle)
            return tilted.mixed(with: .identity, Double(settled))
        case .tiltOut:
            let tilted = ScreenTransform3D(
                rotationX: degrees(20),
                rotationY: degrees(-14),
                scale: 1 - 0.14 * strength,
                shiftY: 24 * strength
            )
            return ScreenTransform3D.identity.mixed(with: tilted, progress * progress * progress)
        case .float:
            let hover = ScreenTransform3D(
                rotationX: degrees(5) * sin(2 * .pi * elapsed / 6.5),
                rotationY: degrees(7) * sin(2 * .pi * elapsed / 9 + 0.8),
                rotationZ: degrees(0.8) * sin(2 * .pi * elapsed / 11),
                scale: 1 - 0.05 * strength,
                shiftY: 8 * strength * sin(2 * .pi * elapsed / 5.5)
            )
            return ScreenTransform3D.identity.mixed(with: hover, envelope(move, at: time))
        case .orbit:
            let swing = ScreenTransform3D(
                rotationX: degrees(-8),
                rotationY: degrees(-18 + 36 * easeInOut(progress)),
                scale: 1 - 0.1 * strength
            )
            return ScreenTransform3D.identity.mixed(with: swing, envelope(move, at: time))
        case .pushIn:
            let push = ScreenTransform3D(
                rotationX: degrees(-6) * easeInOut(progress),
                scale: 1 + 0.16 * strength * easeInOut(progress)
            )
            // Starts flat on its own; eases back flat at the end.
            let ending = min(max((move.span.end - time) / edge, 0), 1)
            return ScreenTransform3D.identity.mixed(with: push, smoothstep(ending))
        }
    }

    /// 0 at a move's ends, 1 once it's under way.
    static func envelope(_ move: CameraMove, at time: TimeInterval) -> Double {
        let ramp = min(edge, move.span.duration / 3)
        guard ramp > 0 else { return 1 }
        return smoothstep(min(max(min(time - move.span.start, move.span.end - time) / ramp, 0), 1))
    }

    static func smoothstep(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    static func easeInOut(_ value: Double) -> Double {
        smoothstep(value)
    }
}

/// Where the recording's frame, and points on it, land on the canvas under a transform,
/// seen in perspective from 1.6 times the canvas's diagonal away. Core Image space (y up).
struct ScreenProjection {
    let frame: CGRect
    let transform: ScreenTransform3D
    let focalLength: Double
    /// Points per 1080p point.
    let unit: Double

    init(frame: CGRect, canvas: CGSize, transform: ScreenTransform3D) {
        self.frame = frame
        self.transform = transform
        focalLength = 1.6 * hypot(Double(canvas.width), Double(canvas.height))
        unit = Double(CanvasLayout.referenceUnit(for: canvas))
    }

    /// Where `point` (on the flat frame) appears. Exactly `point` for the identity.
    func project(_ point: CGPoint) -> CGPoint {
        guard !transform.isIdentity else { return point }
        var x = Double(point.x - frame.midX) * transform.scale
        var y = Double(point.y - frame.midY) * transform.scale
        var z = 0.0

        let (sinX, cosX) = (sin(transform.rotationX), cos(transform.rotationX))
        (y, z) = (y * cosX - z * sinX, y * sinX + z * cosX)
        let (sinY, cosY) = (sin(transform.rotationY), cos(transform.rotationY))
        (x, z) = (x * cosY + z * sinY, -x * sinY + z * cosY)
        let (sinZ, cosZ) = (sin(transform.rotationZ), cos(transform.rotationZ))
        (x, y) = (x * cosZ - y * sinZ, x * sinZ + y * cosZ)

        x += transform.shiftX * unit
        y += transform.shiftY * unit
        // Nearer is bigger; never past the camera.
        let perspective = focalLength / max(focalLength - z, focalLength * 0.1)
        return CGPoint(x: Double(frame.midX) + x * perspective, y: Double(frame.midY) + y * perspective)
    }

    /// The frame's corners as they appear (Core Image space: top has the larger y).
    var topLeft: CGPoint { project(CGPoint(x: frame.minX, y: frame.maxY)) }
    var topRight: CGPoint { project(CGPoint(x: frame.maxX, y: frame.maxY)) }
    var bottomLeft: CGPoint { project(CGPoint(x: frame.minX, y: frame.minY)) }
    var bottomRight: CGPoint { project(CGPoint(x: frame.maxX, y: frame.minY)) }
}
