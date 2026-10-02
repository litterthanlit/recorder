import AVFoundation
import CoreImage
import Foundation

/// critique_video: renders stills of the finished video, scores them (Critic), shows the
/// worst, and makes Trace's fixes for them on request, round after round.
@MainActor
enum AgentCritiqueTools {
    static let defaultCount = 3
    static let maximumCount = 6
    static let maximumRounds = 5

    static func critiqueVideo(_ arguments: AgentArguments, _ context: AgentToolContext) async throws -> JSONValue {
        try context.ensureNotRecording()
        let summary = try context.resolveTake(arguments)
        let count = min(max(try arguments.int("count") ?? defaultCount, 1), maximumCount)
        let fix = try arguments.bool("fix") ?? false
        let rounds = min(max(try arguments.int("rounds") ?? 1, 1), maximumRounds)
        let app = try arguments.string("app")
        var shape: OutputAspect?
        if let text = try arguments.string("aspect") {
            guard let parsed = AgentAspect.parse(text) else {
                throw AgentToolError("aspect must be one of \(AgentAspect.choices) (got \"\(text)\").")
            }
            guard !fix else {
                throw AgentToolError("fix works on the take's own shape (a fix changes every shape). Critique \(text) without fix, or change the take's shape with set_style first.")
            }
            shape = parsed
        }
        let reframe = try arguments.bool("reframe") ?? true
        // The renderer draws the recorded cursor with the system's own images.
        SystemCursorImages.shared.load()

        var scores: [Int] = []
        var fixed: [[String]] = []
        var live = false
        var last: (critique: Critique, project: RecorderProject, edit: EditorSnapshot)?
        for pass in 0...(fix ? rounds : 0) {
            try context.ensureNotRecording()
            let take = try context.load(summary)
            let project = take.project
            try AgentAnalysisTools.checkApp(app, in: project)
            let source = AgentEditTake(project: project, looks: [])
            var edit = EditorSnapshot(keyframes: take.keyframes, editSettings: take.editSettings)
            if let shape {
                edit = edit.variant(for: shape, reframe: reframe, take: source)
            }
            let moments = Critic.moments(edit, duration: project.metadata.duration)
            guard !moments.isEmpty else {
                throw AgentToolError("The edit is empty: there's nothing to critique.")
            }
            let share = 0.85 / Double((fix ? rounds : 0) + 1)
            let progress = context.progress
            let measuring = MCPProgress { value, message in
                progress.report(Double(pass) * share + value * share, message)
            }
            let stills = try await AgentCritiqueRenderer.measure(project, snapshot: edit, moments: moments, progress: measuring)
            let analysis = AgentAnalysisTools.analyze(project, scan: TakeMediaScan(frameTimes: [], screen: nil, speech: nil), app: app)
            let canvas = edit.editSettings.canvasPixelSize(source: source.sourceSize)
            let critique = Critic.judge(stills, snapshot: edit, take: source, canvas: canvas, analysis: analysis)
            scores.append(critique.score)
            last = (critique, project, edit)
            guard fix, pass < rounds else { break }

            let fixes = critique.worst(count).flatMap { still in still.issues.compactMap { $0.fix } }
            guard !fixes.isEmpty else { break }
            var notes: [String] = []
            let applied = try AgentEditTools.applyEdit("Fix \(count) Worst Stills", arguments, context) { snapshot, take in
                notes = Critic.apply(fixes, to: &snapshot, take: take)
                return notes
            }
            live = applied.live
            fixed.append(notes)
        }
        guard let last else {
            throw AgentToolError("Couldn't critique the take.")
        }

        let worst = last.critique.worst(count)
        var images: [Data] = []
        if !worst.isEmpty {
            let moments = worst.map { AgentFrameMoment(source: $0.moment.source, output: $0.moment.output) }
            let progress = context.progress
            images = try await AgentTakeTools.renderFrames(
                last.project,
                snapshot: last.edit,
                moments: moments,
                rendered: true,
                asSheet: true,
                grid: false,
                labelTimeBase: .output,
                progress: MCPProgress { value, message in progress.report(0.85 + value * 0.15, message) }
            )
        }

        var value = last.critique.json(worst: count).objectValue ?? [:]
        value["take_id"] = .string(summary.id.uuidString)
        value["score_history"] = .array(scores.map { JSONValue.number(Double($0)) })
        value["fixes"] = .array(fixed.map { round in JSONValue.array(round.map { JSONValue.string($0) }) })
        if let shape {
            value["aspect"] = .string(AgentAspect.name(shape))
        }
        if !fixed.isEmpty {
            value["live_in_editor"] = .bool(live)
        }
        if !images.isEmpty {
            value["preview"] = .string("A contact sheet of the worst stills, worst first, as they will export; their issues are in worst, in the same order.")
        }
        return MCPToolResult.structured(
            .object(value),
            summary: summaryLine(scores: scores, fixed: fixed, critique: last.critique, count: count),
            images: images.map { (data: $0, mimeType: "image/jpeg") }
        )
    }

    private static func summaryLine(scores: [Int], fixed: [[String]], critique: Critique, count: Int) -> String {
        var parts: [String] = []
        if scores.count > 1, let first = scores.first, let latest = scores.last {
            let made = fixed.reduce(0) { $0 + $1.count }
            parts.append("Scored \(first)/100, then \(latest)/100 after \(made) fix\(made == 1 ? "" : "es") over \(fixed.count) round\(fixed.count == 1 ? "" : "s").")
        } else {
            parts.append("Scored \(critique.score)/100 over \(critique.stills.count) stills.")
        }
        let worst = critique.worst(count)
        if worst.isEmpty {
            parts.append("No still has a problem Trace can see; look at the video yourself for taste.")
        } else {
            let open = worst.flatMap(\.issues).filter { $0.fix != nil }.count
            parts.append("The \(worst.count) worst are in the sheet\(open > 0 ? "; fix: true makes \(open) fix\(open == 1 ? "" : "es")" : "")." )
        }
        if !critique.overall.isEmpty {
            parts.append(critique.overall.map(\.message).joined(separator: " "))
        }
        return parts.joined(separator: " ")
    }
}

/// Renders stills of the finished video for judging: without text (what the text sits
/// on), shrunk to a `LumaGrid`, with where each piece of text is.
enum AgentCritiqueRenderer {
    /// The grid's width in cells; its height follows the canvas's shape.
    static let gridWidth = 64
    /// Stills are composited this wide: plenty for a 64-cell grid.
    static let renderWidth: CGFloat = 480

    static func measure(
        _ project: RecorderProject,
        snapshot: EditorSnapshot,
        moments: [CritiqueMoment],
        progress: MCPProgress
    ) async throws -> [StillMeasurement] {
        let settings = snapshot.editSettings
        let source = CGSize(width: project.metadata.width, height: project.metadata.height)
        let canvas = settings.canvasPixelSize(source: source)
        var bare = CompositionRenderSettings(project: project, editSettings: settings)
        bare.textOverlays = []
        let keyframes = snapshot.keyframes
        let overlays = settings.textOverlays
        let videoURL = project.videoURL
        return try await Task.detached(priority: .userInitiated) {
            try await render(
                videoURL: videoURL,
                settings: bare,
                keyframes: keyframes,
                overlays: overlays,
                canvas: canvas,
                moments: moments,
                progress: progress
            )
        }.value
    }

    private static func render(
        videoURL: URL,
        settings: CompositionRenderSettings,
        keyframes: [ZoomKeyframe],
        overlays: [TextOverlay],
        canvas: CGSize,
        moments: [CritiqueMoment],
        progress: MCPProgress
    ) async throws -> [StillMeasurement] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // Composited from full-size frames, as the export is: click and cursor positions
        // are in the recording's own pixels.
        generator.maximumSize = .zero

        let small = FrameSampling.fitted(canvas, longEdge: renderWidth)
        let width = max(Int(small.width), 2)
        let height = max(Int(small.height), 2)
        let context = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var renderer: CompositionRenderer?
        var result: [StillMeasurement] = []
        for (index, moment) in moments.enumerated() {
            try Task.checkCancellation()
            let frame = try await generator.image(at: CMTime(seconds: moment.source, preferredTimescale: 6000)).image
            if renderer == nil {
                var sized = settings
                sized.sourceWidth = CGFloat(frame.width)
                sized.sourceHeight = CGFloat(frame.height)
                renderer = CompositionRenderer(keyframes: keyframes, settings: sized, ciContext: context)
            }
            guard let composited = renderer?.renderImage(
                source: CIImage(cgImage: frame),
                at: moment.source,
                outputTime: moment.output,
                outputWidth: width,
                outputHeight: height
            ), let image = context.createCGImage(
                composited,
                from: CGRect(x: 0, y: 0, width: width, height: height),
                format: .RGBA8,
                colorSpace: colorSpace
            ) else {
                throw AgentToolError("Couldn't render the still at \(Timecode.precise(moment.output)).")
            }
            let texts = overlays.compactMap { overlay -> StillMeasurement.Text? in
                guard TextMotion.state(for: overlay, at: moment.source).isVisible, canvas.width > 0, canvas.height > 0 else { return nil }
                // Core Image space (bottom-left origin) to normalized, top-left origin.
                let plate = TextPlateLayout.frame(for: overlay, canvas: canvas)
                return StillMeasurement.Text(
                    id: overlay.id,
                    frame: CGRect(
                        x: plate.minX / canvas.width,
                        y: 1 - plate.maxY / canvas.height,
                        width: plate.width / canvas.width,
                        height: plate.height / canvas.height
                    )
                )
            }
            result.append(StillMeasurement(moment: moment, backdrop: grid(image, width: gridWidth), texts: texts))
            progress.report(Double(index + 1) / Double(moments.count), "Still \(index + 1) of \(moments.count)")
        }
        return result
    }

    /// `image` shrunk to a grid `width` cells wide, in brightness from the top-left.
    static func grid(_ image: CGImage, width: Int) -> LumaGrid {
        let height = max(1, Int((Double(width) * Double(image.height) / Double(max(image.width, 1))).rounded()))
        var bytes = [UInt8](repeating: 0, count: width * height)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        // A bitmap context's memory starts with the top row.
        let values = drawn ? bytes.map { Double($0) / 255 } : [Double](repeating: 0, count: width * height)
        return LumaGrid(width: width, height: height, values: values)
    }
}
