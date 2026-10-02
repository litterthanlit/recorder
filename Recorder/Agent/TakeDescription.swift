import CoreGraphics
import Foundation

/// Finds the take an agent means: its id, its name, or "latest".
enum TakeResolver {
    static let latestWords: Set<String> = ["latest", "last", "newest", "recent", "current"]

    static func resolve(_ reference: String?, in takes: [ProjectSummary]) throws -> ProjectSummary {
        let newestFirst = takes.sorted { $0.createdAt > $1.createdAt }
        guard let newest = newestFirst.first else {
            throw AgentToolError("Trace's library has no takes yet. Record one first (⇧⌘R).")
        }
        let wanted = reference?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if wanted.isEmpty || latestWords.contains(wanted.lowercased()) {
            return newest
        }
        if let id = UUID(uuidString: wanted) {
            if let match = takes.first(where: { $0.id == id }) {
                return match
            }
            throw AgentToolError("No take has the id \(wanted). list_takes shows them all.")
        }
        let exact = newestFirst.filter {
            $0.displayName.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        if exact.count == 1 {
            return exact[0]
        }
        if exact.count > 1 {
            throw ambiguous(wanted, exact)
        }
        let partial = newestFirst.filter { $0.matches(wanted) }
        if partial.count == 1 {
            return partial[0]
        }
        if partial.count > 1 {
            throw ambiguous(wanted, partial)
        }
        throw AgentToolError("No take is called \"\(wanted)\". list_takes shows them all; pass a take_id.")
    }

    private static func ambiguous(_ wanted: String, _ matches: [ProjectSummary]) -> AgentToolError {
        let listed = matches.prefix(8).map { "\($0.displayName) (\($0.id.uuidString))" }.joined(separator: "; ")
        return AgentToolError("Several takes match \"\(wanted)\": \(listed). Pass a take_id.")
    }
}

/// Video shapes the way agents write them ("16:9", not "widescreen").
enum AgentAspect {
    static let names: [(OutputAspect, String)] = [
        (.widescreen, "16:9"),
        (.standard, "4:3"),
        (.square, "1:1"),
        (.portrait, "9:16"),
        (.vertical, "4:5"),
        (.auto, "auto")
    ]

    static func name(_ aspect: OutputAspect) -> String {
        names.first { $0.0 == aspect }?.1 ?? aspect.rawValue
    }

    /// "16:9", "9:16", "1:1", "square", "widescreen", "auto"…
    static func parse(_ text: String) -> OutputAspect? {
        let normalized = text.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "x", with: ":")
            .replacingOccurrences(of: "/", with: ":")
        if let match = names.first(where: { $0.1 == normalized }) {
            return match.0
        }
        switch normalized {
        case "landscape", "wide": return .widescreen
        case "vertical_video", "reel", "reels", "shorts", "story", "tiktok": return .portrait
        default: return OutputAspect(rawValue: normalized)
        }
    }

    static var choices: String {
        names.map { $0.1 }.joined(separator: ", ")
    }
}

/// What agents read about takes (list_takes and get_take): times in seconds, places on
/// the recording normalized with a top-left origin.
enum TakeDescription {
    static func listEntry(
        summary: ProjectSummary,
        metadata: ProjectMetadata?,
        editSettings: ProjectEditSettings?,
        isOpen: Bool
    ) -> JSONValue {
        var entry: [String: JSONValue] = [
            "take_id": .string(summary.id.uuidString),
            "name": .string(summary.displayName),
            "created_at": .string(isoDate(summary.createdAt)),
            "duration": AgentTime.json(summary.duration),
            "open_in_editor": .bool(isOpen)
        ]
        if let metadata {
            entry["capture"] = .string(metadata.captureTarget.rawValue)
            entry["size"] = .string("\(metadata.width)x\(metadata.height)")
            if let app = metadata.appName, !app.isEmpty {
                entry["app"] = .string(app)
            }
        }
        if let editSettings {
            let timeline = editSettings.resolvedTimeline(sourceDuration: summary.duration)
            entry["output_duration"] = AgentTime.json(timeline.outputDuration)
            entry["edited"] = .bool(isEdited(editSettings, timeline: timeline, duration: summary.duration))
        }
        if let export = summary.latestExport {
            entry["last_export"] = .string(export.path)
        }
        return .object(entry)
    }

    /// Cut, trimmed, sped up, or given text or blur.
    static func isEdited(_ settings: ProjectEditSettings, timeline: EditTimeline, duration: TimeInterval) -> Bool {
        timeline.hasCuts
            || timeline.hasSpeedChanges
            || timeline.trimStart > 0.05
            || timeline.trimEnd < duration - 0.05
            || !settings.textOverlays.isEmpty
            || !settings.blurRegions.isEmpty
            || settings.sourceCrop != nil
    }

    static func detail(
        project: RecorderProject,
        keyframes: [ZoomKeyframe],
        editSettings: ProjectEditSettings,
        isOpen: Bool
    ) -> JSONValue {
        let metadata = project.metadata
        let timeline = editSettings.resolvedTimeline(sourceDuration: metadata.duration)
        let source = CGSize(width: metadata.width, height: metadata.height)
        var detail: [String: JSONValue] = [
            "take_id": .string(metadata.id.uuidString),
            "name": .string(metadata.name ?? ProjectSummary.title(for: metadata)),
            "created_at": .string(isoDate(metadata.createdAt)),
            "duration": AgentTime.json(metadata.duration),
            "output_duration": AgentTime.json(timeline.outputDuration),
            "capture": .string(metadata.captureTarget.rawValue),
            "open_in_editor": .bool(isOpen),
            "zoom_preset": .string(editSettings.zoomPreset.rawValue)
        ]
        let sourceInfo: JSONValue = [
            "width": .number(Double(metadata.width)),
            "height": .number(Double(metadata.height)),
            "fps": .number(Double(metadata.fps)),
            "scale_factor": .finite(Double(metadata.scaleFactor))
        ]
        detail["source"] = sourceInfo
        detail["timeline"] = timelineJSON(timeline, duration: metadata.duration)
        let zooms = keyframes.sorted { $0.startTime < $1.startTime }
        detail["zooms"] = .array(zooms.map(zoomJSON))
        detail["text"] = .array(editSettings.textOverlays.map(textJSON))
        detail["blur"] = .array(editSettings.blurRegions.map(blurJSON))
        detail["look"] = lookJSON(editSettings.exportStyle)
        detail["canvas"] = canvasJSON(editSettings.canvas, source: editSettings.contentSize(source: source))
        detail["crop"] = cropJSON(editSettings.sourceCrop, source: source)
        detail["motion"] = motionJSON(editSettings, timeline: timeline)
        let audio: JSONValue = [
            "tracks": .array(metadata.audioTrackRoles.map { JSONValue.string($0.rawValue) }),
            "microphone_volume": .finite(editSettings.audio.microphoneVolume),
            "system_audio_volume": .finite(editSettings.audio.systemAudioVolume)
        ]
        detail["audio"] = audio
        let input: JSONValue = [
            "clicks": .number(Double(project.clickEvents.count)),
            "keystrokes": .number(Double(project.inputs.keystrokes.count)),
            "cursor_samples": .number(Double(project.cursorEvents.count))
        ]
        detail["recorded_input"] = input
        if let app = metadata.appName, !app.isEmpty {
            detail["app"] = .string(app)
        }
        if let window = metadata.windowTitle, !window.isEmpty {
            detail["window_title"] = .string(window)
        }
        if !metadata.pausePoints.isEmpty {
            detail["pause_points"] = .array(metadata.pausePoints.map(AgentTime.json))
        }
        if project.hasCameraTrack {
            detail["camera"] = [
                "visible": .bool(editSettings.camera.isVisible),
                "position": .string(editSettings.camera.position.rawValue),
                "shape": .string(editSettings.camera.shape.rawValue)
            ]
        }
        return .object(detail)
    }

    static func timelineJSON(_ timeline: EditTimeline, duration: TimeInterval) -> JSONValue {
        let segments = zip(timeline.segments, timeline.outputSpans).enumerated().map { index, pair -> JSONValue in
            [
                "index": .number(Double(index)),
                "segment_id": .string(pair.0.id.uuidString),
                "source": spanJSON(pair.0.source),
                "output": spanJSON(pair.1),
                "speed": .finite(pair.0.speed)
            ]
        }
        return [
            "segments": .array(segments),
            "removed": .array(removedSpans(timeline, duration: duration).map(spanJSON))
        ]
    }

    /// Source time the edit leaves out: before the first segment, between segments and
    /// after the last.
    static func removedSpans(_ timeline: EditTimeline, duration: TimeInterval) -> [TimeSpan] {
        var spans: [TimeSpan] = []
        var covered: TimeInterval = 0
        for segment in timeline.segments {
            if segment.source.start - covered > 0.001 {
                spans.append(TimeSpan(start: covered, end: segment.source.start))
            }
            covered = max(covered, segment.source.end)
        }
        if duration - covered > 0.001 {
            spans.append(TimeSpan(start: covered, end: duration))
        }
        return spans
    }

    static func spanJSON(_ span: TimeSpan) -> JSONValue {
        ["start": AgentTime.json(span.start), "end": AgentTime.json(span.end)]
    }

    static func zoomJSON(_ keyframe: ZoomKeyframe) -> JSONValue {
        [
            "zoom_id": .string(keyframe.id.uuidString),
            "start": AgentTime.json(keyframe.startTime),
            "peak": AgentTime.json(keyframe.peakTime),
            "end": AgentTime.json(keyframe.endTime),
            "center": AgentCoordinates.json(sourcePoint: keyframe.center),
            "scale": .finite((Double(keyframe.scale) * 100).rounded() / 100),
            "kind": .string(keyframe.source.rawValue)
        ]
    }

    static func textJSON(_ overlay: TextOverlay) -> JSONValue {
        [
            "text_id": .string(overlay.id.uuidString),
            "text": .string(overlay.text),
            "style": .string(overlay.style.rawValue),
            "start": AgentTime.json(overlay.span.start),
            "end": AgentTime.json(overlay.span.end),
            "position": AgentCoordinates.json(canvasPoint: overlay.center),
            "scale": .finite(overlay.scale),
            "animation": .string(overlay.animation.rawValue)
        ]
    }

    static func blurJSON(_ region: BlurRegion) -> JSONValue {
        [
            "blur_id": .string(region.id.uuidString),
            "start": AgentTime.json(region.span.start),
            "end": AgentTime.json(region.span.end),
            "rect": AgentCoordinates.json(sourceRect: region.rect),
            "kind": .string(region.kind.rawValue),
            "strength": .finite(region.strength)
        ]
    }

    static func lookJSON(_ style: ExportStyle) -> JSONValue {
        let background = style.background
        var backdrop: [String: JSONValue] = ["kind": .string(background.kind.rawValue)]
        switch background.kind {
        case .wallpaper:
            backdrop["wallpaper"] = .string(background.wallpaper.rawValue)
        case .gradient:
            backdrop["from"] = .string(background.gradientStart.hexString)
            backdrop["to"] = .string(background.gradientEnd.hexString)
            backdrop["angle"] = .finite(background.gradientAngle)
        case .solid:
            backdrop["color"] = .string(background.solidColor.hexString)
        case .image:
            backdrop["image"] = background.imageFileName.map { JSONValue.string($0) } ?? JSONValue.null
        case .none:
            break
        }
        let cursor: JSONValue = [
            "visible": .bool(style.showCursor),
            "size": .finite(style.cursorSize),
            "smoothing": .bool(style.cursorSmoothingEnabled),
            "hide_when_idle": .bool(style.hideIdleCursor),
            "click_bounce": .bool(style.cursorScaleOnClickEnabled)
        ]
        let watermark: JSONValue = style.watermarkEnabled ? JSONValue.string(style.watermarkText) : JSONValue.null
        return [
            "background": .object(backdrop),
            "padding": .finite(Double(style.paddingRatio)),
            "corner_radius": .finite(Double(style.cornerRadius)),
            "shadow": .bool(style.shadowEnabled),
            "cursor": cursor,
            "click_ripples": .bool(style.clickRipplesEnabled),
            "spotlight": .bool(style.cursorSpotlightEnabled),
            "motion_blur": .bool(style.motionBlurEnabled),
            "spring_camera": .bool(style.springCameraEnabled),
            "keystrokes": .string(style.keystrokes.filter.rawValue),
            "watermark": watermark
        ]
    }

    /// Transitions, speed ramps and audio at cuts.
    static func motionJSON(_ settings: ProjectEditSettings, timeline: EditTimeline) -> JSONValue {
        var transition = JSONValue.null
        if let cut = settings.cutTransition {
            transition = ["style": .string(cut.style.rawValue), "duration": AgentTime.json(cut.duration)]
        }
        return [
            "cut_transition": transition,
            "smooth_speed_changes": .bool(timeline.hasSpeedRamps),
            "cut_audio_fades": .bool(settings.audio.cutFades),
            "mute_sped_up_audio": .bool(settings.audio.muteSpedUp)
        ]
    }

    /// The crop, as agents read rects (origin top-left), with its size in pixels.
    static func cropJSON(_ crop: CGRect?, source: CGSize) -> JSONValue {
        guard let crop = crop.flatMap({ SourceCrop.sanitized($0) }) else { return .null }
        let size = SourceCrop.contentSize(source: source, crop: crop)
        return [
            "rect": AgentCoordinates.json(sourceRect: crop),
            "pixels": .string("\(Int(size.width.rounded()))x\(Int(size.height.rounded()))")
        ]
    }

    /// - Parameter source: the picture's size once cropped.
    static func canvasJSON(_ canvas: CanvasSpec, source: CGSize) -> JSONValue {
        let size = canvas.pixelSize(source: source)
        return [
            "aspect": .string(AgentAspect.name(canvas.aspect)),
            "resolution": .string(canvas.resolution.rawValue),
            "output_size": .string("\(Int(size.width))x\(Int(size.height))")
        ]
    }

    static func isoDate(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
