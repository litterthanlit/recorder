import CoreGraphics
import Foundation

/// A storyboard an agent writes for a take: shots on the recording, in order, each with a
/// camera move and kinetic type, from a hook in the first seconds to a payoff every few.
/// `StoryboardRecipe` turns it into the edit.
struct Storyboard: Equatable {
    struct Shot: Equatable {
        enum Role: String, CaseIterable {
            /// Grabs attention in the first seconds.
            case hook
            /// Shows a step.
            case step
            /// Shows a result: the moment that rewards watching.
            case payoff
        }

        var role: Role
        /// Source seconds.
        var span: TimeSpan
        /// How fast it plays.
        var speed: Double
        var camera: Camera
        var text: Text?
        /// When its result shows (source seconds), for the rhythm of payoffs.
        var payoffAt: TimeInterval?

        /// How long it lasts in the video.
        var outputDuration: TimeInterval {
            span.duration / speed
        }
    }

    struct Camera: Equatable {
        enum Move: String, CaseIterable {
            /// Rests on the picture.
            case hold
            /// Zooms onto the clicks as they happen.
            case auto
            /// Zooms in on the target as the shot starts, then holds.
            case zoom
            /// Moves slowly closer to the target over the whole shot.
            case push
            /// Starts close on the target and slowly pulls back to the whole picture.
            case pull
            /// Moves from the target to `to`, close up.
            case pan
        }

        var move: Move
        /// Where to look (normalized, bottom-left origin); `nil` aims at the shot's action.
        var target: CGRect?
        /// The other end of a pan.
        var to: CGRect?
        /// How close; `nil` picks one for the move (or fits `target`).
        var scale: CGFloat?
        /// A 3D move of the frame over the shot.
        var threeD: CameraMoveKind?

        static let hold = Camera(move: .hold)

        init(move: Move, target: CGRect? = nil, to: CGRect? = nil, scale: CGFloat? = nil, threeD: CameraMoveKind? = nil) {
            self.move = move
            self.target = target
            self.to = to
            self.scale = scale
            self.threeD = threeD
        }
    }

    struct Text: Equatable {
        var text: String
        var style: TextOverlay.Style
        var animation: TextAnimation
        /// Canvas position, normalized with a top-left origin.
        var position: CGPoint
        /// When it comes on, in seconds of the video after the shot starts.
        var at: TimeInterval
        /// How long it stays (video seconds); `nil` is long enough to read.
        var hold: TimeInterval?
    }

    var shots: [Shot]
    /// The app it's about: the video is cropped to its window and other apps over it are
    /// hidden.
    var app: String?
    var cropToApp = true
    var look: String?
    var aspect: OutputAspect?
    var reframe: Bool?
    /// At the cuts between shots; `nil` cuts straight.
    var transition: CutTransitionStyle? = .zoomBlur

    static let maximumShots = 40
    /// Shorter shots flash by.
    static let minimumShot: TimeInterval = 0.4
}

// MARK: - Reading agents' storyboards

extension Storyboard {
    /// render_storyboard's arguments. Times are source seconds; rects and points are
    /// normalized with a top-left origin, like everything agents send.
    init(_ arguments: AgentArguments, duration: TimeInterval) throws {
        guard let list = try arguments.objects("shots"), !list.isEmpty else {
            throw AgentToolError("shots is required: a list like [{\"start\": 2, \"end\": 5, \"camera\": \"zoom\", \"text\": \"Connect your repo\"}].")
        }
        guard list.count <= Self.maximumShots else {
            throw AgentToolError("At most \(Self.maximumShots) shots; a demo reads better with a few strong ones.")
        }
        var shots: [Shot] = []
        for (index, shot) in list.enumerated() {
            do {
                let role = try shot.choice("role", Shot.Role.self)
                    ?? (index == 0 ? .hook : (index == list.count - 1 && list.count > 2 ? .payoff : .step))
                shots.append(try Self.shot(shot, role: role, duration: duration))
            } catch let error as AgentToolError {
                throw AgentToolError("shots[\(index)]: \(error.message)")
            }
        }
        for index in shots.indices.dropFirst() where shots[index].span.start < shots[index - 1].span.end - 1e-6 {
            throw AgentToolError(
                "shots[\(index)] starts at \(AgentArguments.format(shots[index].span.start)) s, before shots[\(index - 1)] ends at \(AgentArguments.format(shots[index - 1].span.end)) s. Shots follow the recording in order without overlapping: Trace plays it forward only."
            )
        }
        self.init(shots: shots)
        app = try arguments.string("app").map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        cropToApp = try arguments.bool("crop_to_app") ?? true
        look = try arguments.string("look").map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        if let shape = try arguments.string("aspect") {
            guard let parsed = AgentAspect.parse(shape) else {
                throw AgentToolError("aspect must be one of \(AgentAspect.choices) (got \"\(shape)\").")
            }
            aspect = parsed
        }
        reframe = try arguments.bool("reframe")
        if let name = try arguments.string("transition") {
            switch AgentEdits.parseTransition(name) {
            case let .style(style)?:
                transition = style
            case .straight?:
                transition = nil
            case nil:
                throw AgentToolError("transition must be zoom_blur, whip, blur_dip or none (got \"\(name)\").")
            }
        }
    }

    private static func shot(_ arguments: AgentArguments, role: Shot.Role, duration: TimeInterval) throws -> Shot {
        guard let start = try arguments.time("start"), let end = try arguments.time("end") else {
            throw AgentToolError("start and end are required (source seconds on the recording).")
        }
        guard start >= -0.001, end <= duration + 0.001 else {
            throw AgentToolError("\(AgentArguments.format(start))–\(AgentArguments.format(end)) s is outside the recording (0–\(AgentArguments.format(duration)) s).")
        }
        let span = TimeSpan(start: max(start, 0), end: min(end, duration))
        guard span.duration >= minimumShot - 1e-9 else {
            throw AgentToolError("A shot needs at least \(AgentArguments.format(minimumShot)) s of the recording (got \(AgentArguments.format(span.duration)) s).")
        }
        var speed = try arguments.double("speed", in: EditTimeline.speedRange) ?? 1
        if let length = try arguments.double("duration") {
            guard length > 0 else { throw AgentToolError("duration must be more than 0.") }
            speed = min(max(span.duration / length, EditTimeline.speedRange.lowerBound), EditTimeline.speedRange.upperBound)
        }
        var payoffAt: TimeInterval?
        if let time = try arguments.time("payoff_at") {
            guard span.contains(time) || abs(time - span.end) < 1e-6 else {
                throw AgentToolError("payoff_at (\(AgentArguments.format(time)) s) must be inside the shot.")
            }
            payoffAt = time
        }
        return Shot(
            role: role,
            span: span,
            speed: speed,
            camera: try camera(arguments),
            text: try text(arguments, role: role),
            payoffAt: payoffAt
        )
    }

    private static func camera(_ arguments: AgentArguments) throws -> Camera {
        guard let value = arguments.value("camera") else { return .hold }
        if let name = value.stringValue {
            return Camera(move: try move(name), threeD: nil)
        }
        guard let object = value.objectValue else {
            throw AgentToolError("camera must be a move's name or {move, rect or point, to, scale, three_d}.")
        }
        let camera = AgentArguments(values: object)
        let move = try camera.string("move").map { try Self.move($0) } ?? .zoom
        var result = Camera(move: move)
        if let rect = try camera.object("rect") {
            result.target = try AgentCoordinates.sourceRect(rect, named: "camera.rect")
        } else if let point = try camera.object("point") {
            let center = try AgentCoordinates.sourcePoint(point, named: "camera.point")
            result.target = CGRect(x: center.x, y: center.y, width: 0, height: 0)
        }
        if let rect = try camera.object("to") {
            result.to = try AgentCoordinates.sourceRect(rect, named: "camera.to")
        }
        let range = ZoomKeyframeEditor.focusScaleRange
        if let scale = try camera.double("scale", in: Double(range.lowerBound)...Double(range.upperBound)) {
            result.scale = CGFloat(scale)
        }
        result.threeD = try camera.choice("three_d", CameraMoveKind.self)
        if move == .pan, result.to == nil {
            throw AgentToolError("A pan needs to: the rect it ends on ({x, y, width, height}, origin top-left).")
        }
        return result
    }

    private static func move(_ name: String) throws -> Camera.Move {
        let key = name.lowercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        switch key {
        case "push_in": return .push
        case "pull_out", "pull_back": return .pull
        case "still", "none", "rest": return .hold
        default:
            guard let move = Camera.Move(rawValue: key) else {
                let names = Camera.Move.allCases.map(\.rawValue).joined(separator: ", ")
                throw AgentToolError("camera must be one of \(names) (got \"\(name)\").")
            }
            return move
        }
    }

    private static func text(_ arguments: AgentArguments, role: Shot.Role) throws -> Text? {
        guard let value = arguments.value("text") else { return nil }
        let style = defaultStyle(for: role)
        if let words = value.stringValue {
            let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return Text(text: trimmed, style: style, animation: defaultAnimation(for: role), position: defaultPosition(for: style), at: defaultAt, hold: nil)
        }
        guard let object = value.objectValue else {
            throw AgentToolError("text must be words, or {text, style, animation, position, at, hold}.")
        }
        let text = AgentArguments(values: object)
        let words = try text.requiredString("text").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { throw AgentToolError("text.text is empty.") }
        let chosen = try text.choice("style", TextOverlay.Style.self) ?? style
        let at = try text.double("at") ?? defaultAt
        guard at >= 0 else { throw AgentToolError("text.at must be 0 or more (seconds into the shot).") }
        let hold = try text.double("hold")
        if let hold, hold < LaunchDemoRecipe.minimumCaption {
            throw AgentToolError("text.hold must be at least \(AgentArguments.format(LaunchDemoRecipe.minimumCaption)) s to be read.")
        }
        return Text(
            text: words,
            style: chosen,
            animation: try text.choice("animation", TextAnimation.self) ?? defaultAnimation(for: role),
            position: try AgentEdits.position(text) ?? defaultPosition(for: chosen),
            at: at,
            hold: hold
        )
    }

    /// Text comes on this far into its shot.
    static let defaultAt: TimeInterval = 0.15

    static func defaultStyle(for role: Shot.Role) -> TextOverlay.Style {
        role == .step ? .caption : .title
    }

    static func defaultAnimation(for role: Shot.Role) -> TextAnimation {
        switch role {
        case .hook: return .rise
        case .step: return .pop
        case .payoff: return .pop
        }
    }

    static func defaultPosition(for style: TextOverlay.Style) -> CGPoint {
        switch style {
        case .title: return LaunchDemoRecipe.titleCenter
        case .caption: return LaunchDemoRecipe.captionCenter
        case .callout: return CGPoint(x: 0.5, y: 0.14)
        }
    }
}
