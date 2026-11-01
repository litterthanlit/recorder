import CoreGraphics
import Foundation

extension AgentEdits {
    /// set_style: a look, then any individual settings on top of it.
    static func setStyle(_ snapshot: inout EditorSnapshot, arguments: AgentArguments, take: AgentEditTake) throws -> [String] {
        var settings = snapshot.editSettings
        var keyframes = snapshot.keyframes
        var notes: [String] = []

        func regenerateZooms(for preset: ZoomPreset) {
            keyframes = ZoomKeyframeEditor.replacingAutoZooms(
                in: keyframes,
                clicks: take.clicks,
                preset: preset,
                frameSize: take.sourceSize
            )
        }

        if let name = try arguments.string("look") {
            let look = try self.look(named: name, in: take.looks)
            let zoomChanged = look.zoomPreset != settings.zoomPreset
            look.apply(to: &settings)
            if zoomChanged {
                regenerateZooms(for: look.zoomPreset)
            }
            notes.append("Applied the \(look.name) look.")
        }
        if let background = try arguments.object("background") {
            notes.append(try applyBackground(background, to: &settings.exportStyle.background))
        }
        if let preset = try arguments.choice("zoom_preset", ZoomPreset.self), preset != settings.zoomPreset {
            settings.zoomPreset = preset
            regenerateZooms(for: preset)
            notes.append("Zoom preset \(preset.rawValue); auto zooms remade.")
        }
        try applyCanvas(arguments, to: &settings.canvas, notes: &notes)
        try applyLook(arguments, to: &settings.exportStyle, notes: &notes)
        try applyAudio(arguments, to: &settings.audio, notes: &notes)
        try applyMotion(arguments, to: &settings, duration: take.duration, notes: &notes)

        guard !notes.isEmpty else {
            throw AgentToolError("Nothing to change: pass at least one setting (look, background, aspect, padding…).")
        }
        snapshot.editSettings = settings
        snapshot.keyframes = keyframes
        return notes
    }

    static func look(named name: String, in looks: [StylePreset]) throws -> StylePreset {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        if let match = looks.first(where: { $0.name.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            return match
        }
        let names = looks.map { "\"\($0.name)\"" }.joined(separator: ", ")
        throw AgentToolError("No look is called \"\(name)\". Looks: \(names).")
    }

    /// `{wallpaper}`, `{color}`, `{from, to, angle?}` or `{kind: "none"}`.
    static func applyBackground(_ arguments: AgentArguments, to background: inout BackgroundStyle) throws -> String {
        if let wallpaper = try arguments.choice("wallpaper", WallpaperPreset.self) {
            background.kind = .wallpaper
            background.wallpaper = wallpaper
            return "Background: the \(wallpaper.rawValue) wallpaper."
        }
        if let color = try arguments.string("color") {
            background.kind = .solid
            background.solidColor = try parseColor(color, key: "color")
            return "Background: solid \(background.solidColor.hexString)."
        }
        if arguments.has("from") || arguments.has("to") {
            guard let from = try arguments.string("from"), let to = try arguments.string("to") else {
                throw AgentToolError("A gradient needs both from and to (hex colours like \"#6E56CF\").")
            }
            background.kind = .gradient
            background.gradientStart = try parseColor(from, key: "from")
            background.gradientEnd = try parseColor(to, key: "to")
            if let angle = try arguments.double("angle", in: 0...360) {
                background.gradientAngle = angle
            }
            return "Background: gradient \(background.gradientStart.hexString) → \(background.gradientEnd.hexString)."
        }
        if let kind = try arguments.choice("kind", BackgroundKind.self) {
            switch kind {
            case .none:
                background.kind = .none
                return "No background: the recording fills the frame."
            case .wallpaper, .gradient, .solid:
                background.kind = kind
                return "Background: \(kind.rawValue)."
            case .image:
                throw AgentToolError("Pictures can only be chosen in Trace's editor. Use a wallpaper, gradient or color.")
            }
        }
        let wallpapers = WallpaperPreset.allCases.map(\.rawValue).joined(separator: ", ")
        throw AgentToolError("background needs wallpaper (\(wallpapers)), color, from and to, or kind \"none\".")
    }

    static func parseColor(_ text: String, key: String) throws -> RGBAColor {
        let digits = text.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit) else {
            throw AgentToolError("\(key) must be a hex colour like \"#6E56CF\" (got \"\(text)\").")
        }
        return RGBAColor(hex: digits)
    }

    /// "720p", "1080p", "1440p", "4k", "source".
    static func parseResolution(_ text: String) -> OutputResolution? {
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "720p", "720", "hd720": return .hd720
        case "1080p", "1080", "hd1080", "full_hd", "fullhd": return .hd1080
        case "1440p", "1440", "qhd1440", "2k": return .qhd1440
        case "4k", "2160p", "2160", "uhd2160", "uhd": return .uhd2160
        case "source", "original", "native": return .source
        default: return nil
        }
    }

    private static func applyCanvas(_ arguments: AgentArguments, to canvas: inout CanvasSpec, notes: inout [String]) throws {
        if let text = try arguments.string("aspect") {
            guard let aspect = AgentAspect.parse(text) else {
                throw AgentToolError("aspect must be one of \(AgentAspect.choices) (got \"\(text)\").")
            }
            canvas.aspect = aspect
            notes.append("Shape \(AgentAspect.name(aspect)).")
        }
        if let text = try arguments.string("resolution") {
            guard let resolution = parseResolution(text) else {
                throw AgentToolError("resolution must be 720p, 1080p, 1440p, 4k or source (got \"\(text)\").")
            }
            canvas.resolution = resolution
            notes.append("Resolution \(resolution.rawValue).")
        }
    }

    private static func applyLook(_ arguments: AgentArguments, to style: inout ExportStyle, notes: inout [String]) throws {
        if let padding = try arguments.double("padding", in: 0...0.3) {
            style.paddingRatio = CGFloat(padding)
            notes.append("Padding \(AgentArguments.format(padding)).")
        }
        if let radius = try arguments.double("corner_radius", in: 0...48) {
            style.cornerRadius = CGFloat(radius)
            notes.append("Corner radius \(AgentArguments.format(radius)).")
        }
        if let size = try arguments.double("cursor_size", in: 0.5...3) {
            style.cursorSize = size
            notes.append("Cursor size \(AgentArguments.format(size))×.")
        }
        if let filter = try arguments.choice("keystrokes", KeystrokeFilter.self) {
            style.keystrokes.filter = filter
            notes.append("Keystrokes: \(filter.rawValue).")
        }
        if let watermark = try arguments.string("watermark") {
            let text = watermark.trimmingCharacters(in: .whitespacesAndNewlines)
            style.watermarkEnabled = !text.isEmpty
            style.watermarkText = text
            notes.append(text.isEmpty ? "No watermark." : "Watermark \"\(text)\".")
        }
        let switches: [(String, WritableKeyPath<ExportStyle, Bool>, String)] = [
            ("shadow", \.shadowEnabled, "Shadow"),
            ("show_cursor", \.showCursor, "Cursor"),
            ("hide_idle_cursor", \.hideIdleCursor, "Hide the cursor when idle"),
            ("cursor_smoothing", \.cursorSmoothingEnabled, "Cursor smoothing"),
            ("click_bounce", \.cursorScaleOnClickEnabled, "Click bounce"),
            ("click_ripples", \.clickRipplesEnabled, "Click ripples"),
            ("spotlight", \.cursorSpotlightEnabled, "Spotlight"),
            ("motion_blur", \.motionBlurEnabled, "Motion blur"),
            ("spring_camera", \.springCameraEnabled, "Spring camera")
        ]
        for (key, keyPath, label) in switches {
            if let on = try arguments.bool(key) {
                style[keyPath: keyPath] = on
                notes.append("\(label) \(on ? "on" : "off").")
            }
        }
    }

    /// What an agent asked for at cuts.
    enum TransitionRequest: Equatable {
        /// Straight cuts.
        case straight
        case style(CutTransitionStyle)
    }

    /// "zoom_blur", "whip", "blur_dip" (or "zoom", "blur"), or "none"; `nil` otherwise.
    static func parseTransition(_ text: String) -> TransitionRequest? {
        let normalized = text.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "-", with: "_")
        switch normalized {
        case "none", "off", "cut":
            return TransitionRequest.straight
        case "zoom":
            return TransitionRequest.style(CutTransitionStyle.zoomBlur)
        case "blur":
            return TransitionRequest.style(CutTransitionStyle.blurDip)
        default:
            return CutTransitionStyle(rawValue: normalized).map { TransitionRequest.style($0) }
        }
    }

    private static func applyMotion(
        _ arguments: AgentArguments,
        to settings: inout ProjectEditSettings,
        duration: TimeInterval,
        notes: inout [String]
    ) throws {
        if let text = try arguments.string("cut_transition") {
            switch parseTransition(text) {
            case let .style(style)?:
                var transition = settings.cutTransition ?? CutTransition()
                transition.style = style
                settings.cutTransition = transition
                notes.append("A \(style.label.lowercased()) transition at every cut.")
            case .straight?:
                settings.cutTransition = nil
                notes.append("Straight cuts.")
            case nil:
                throw AgentToolError("cut_transition must be zoom_blur, whip, blur_dip or none (got \"\(text)\").")
            }
        }
        if let length = try arguments.double("cut_transition_duration", in: CutTransition.durationRange) {
            var transition = settings.cutTransition ?? CutTransition()
            transition.duration = length
            settings.cutTransition = transition
            notes.append("Transitions last \(AgentArguments.format(length)) s.")
        }
        if let smooth = try arguments.bool("smooth_speed_changes") {
            var timeline = settings.resolvedTimeline(sourceDuration: duration)
            timeline.speedRamp = smooth ? SpeedRamp.defaultRamp : nil
            settings.setTimeline(timeline)
            notes.append(smooth ? "Speed changes ease in and out." : "Speed changes jump.")
        }
        if let fades = try arguments.bool("cut_audio_fades") {
            settings.audio.cutFades = fades
            notes.append(fades ? "Audio fades at cuts." : "No audio fades at cuts.")
        }
        if let mute = try arguments.bool("mute_sped_up_audio") {
            settings.audio.muteSpedUp = mute
            notes.append(mute ? "Parts faster than 2.5× are silent." : "Sped-up parts keep their sound.")
        }
    }

    private static func applyAudio(_ arguments: AgentArguments, to audio: inout AudioMixSettings, notes: inout [String]) throws {
        if let volume = try arguments.double("microphone_volume", in: 0...2) {
            audio.microphoneVolume = volume
            notes.append("Microphone at \(Int((volume * 100).rounded()))%.")
        }
        if let volume = try arguments.double("system_audio_volume", in: 0...2) {
            audio.systemAudioVolume = volume
            notes.append("System audio at \(Int((volume * 100).rounded()))%.")
        }
    }
}
