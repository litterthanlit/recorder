import CoreGraphics
import Foundation

/// Agents describe places on the recording the way they see frames: normalized 0–1 with
/// the origin at the top-left. Trace stores them normalized with the origin at the
/// bottom-left (Core Image space). Every conversion goes through here.
enum AgentCoordinates {
    /// An agent's rect (top-left origin) as a source rect (bottom-left origin).
    static func sourceRect(fromTopLeft rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
    }

    /// A source rect (bottom-left origin) as agents see it (top-left origin).
    static func topLeftRect(fromSource rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
    }

    static func sourcePoint(fromTopLeft point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: 1 - point.y)
    }

    static func topLeftPoint(fromSource point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: 1 - point.y)
    }

    /// Reads `{x, y, width, height}` (normalized, top-left origin), checked to lie on the
    /// recording; returns the source rect (bottom-left origin).
    static func sourceRect(_ arguments: AgentArguments, named name: String = "rect") throws -> CGRect {
        guard let x = try arguments.double("x"), let y = try arguments.double("y"),
              let width = try arguments.double("width"), let height = try arguments.double("height")
        else {
            throw AgentToolError("\(name) needs x, y, width and height (0–1, origin at the top-left).")
        }
        let rect = CGRect(x: x, y: y, width: width, height: height)
        let tolerance = 0.001
        guard rect.width > 0.005, rect.height > 0.005,
              rect.minX >= -tolerance, rect.minY >= -tolerance,
              rect.maxX <= 1 + tolerance, rect.maxY <= 1 + tolerance
        else {
            throw AgentToolError("\(name) must lie within 0–1 on both axes with a positive size (got x \(x), y \(y), width \(width), height \(height)).")
        }
        let clamped = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return sourceRect(fromTopLeft: clamped)
    }

    /// Reads `{x, y}` (normalized, top-left origin); returns the source point.
    static func sourcePoint(_ arguments: AgentArguments, named name: String = "point") throws -> CGPoint {
        guard let x = try arguments.double("x"), let y = try arguments.double("y") else {
            throw AgentToolError("\(name) needs x and y (0–1, origin at the top-left).")
        }
        guard (0...1).contains(x), (0...1).contains(y) else {
            throw AgentToolError("\(name) must lie within 0–1 (got x \(x), y \(y)).")
        }
        return sourcePoint(fromTopLeft: CGPoint(x: x, y: y))
    }

    /// A source rect as agents see it, rounded to 4 decimals.
    static func json(sourceRect rect: CGRect) -> JSONValue {
        let shown = topLeftRect(fromSource: rect)
        return ["x": rounded(shown.minX), "y": rounded(shown.minY), "width": rounded(shown.width), "height": rounded(shown.height)]
    }

    static func json(sourcePoint point: CGPoint) -> JSONValue {
        let shown = topLeftPoint(fromSource: point)
        return ["x": rounded(shown.x), "y": rounded(shown.y)]
    }

    /// A canvas point (text positions are already top-left origin).
    static func json(canvasPoint point: CGPoint) -> JSONValue {
        ["x": rounded(point.x), "y": rounded(point.y)]
    }

    static func rounded(_ value: CGFloat) -> JSONValue {
        .finite((Double(value) * 10_000).rounded() / 10_000)
    }
}

/// Which clock a time is on: the recording's own ("source", the default: stable while
/// the edit changes) or the edited video's ("output").
enum AgentTimeBase: String, CaseIterable {
    case source
    case output

    /// `time` on this clock, as source time.
    func sourceTime(_ time: TimeInterval, in timeline: EditTimeline) -> TimeInterval {
        switch self {
        case .source: return time
        case .output: return timeline.sourceTime(forOutput: time)
        }
    }

    /// `span` on this clock, as source time.
    func sourceSpan(_ span: TimeSpan, in timeline: EditTimeline) -> TimeSpan {
        switch self {
        case .source:
            return span
        case .output:
            return TimeSpan(start: timeline.sourceTime(forOutput: span.start), end: timeline.sourceTime(forOutput: span.end))
        }
    }

    /// Reads `time_base` (default `source`).
    static func read(_ arguments: AgentArguments, default fallback: AgentTimeBase = .source) throws -> AgentTimeBase {
        try arguments.choice("time_base", AgentTimeBase.self) ?? fallback
    }
}
