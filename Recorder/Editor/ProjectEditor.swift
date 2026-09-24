import AppKit
import AVFoundation
import Foundation

@MainActor
final class ProjectEditor: ObservableObject {
    enum State: Equatable {
        case editing
        case exporting(progress: Double)
        case exported
        case failed(String)
    }

    @Published var project: RecorderProject
    @Published var keyframes: [ZoomKeyframe]
    @Published var editSettings: ProjectEditSettings
    @Published var playheadTime: TimeInterval = 0
    @Published var selectedKeyframeID: UUID?
    @Published var isManualZoomMode = false
    @Published var isPlaying = false
    @Published private(set) var state: State = .editing
    @Published private(set) var exportProgress: Double = 0

    let player = AVPlayer()

    private let videoExporter = VideoExporter()
    private var timeObserver: Any?

    var duration: TimeInterval {
        project.metadata.duration
    }

    var trimmedDuration: TimeInterval {
        editSettings.trimmedDuration(for: duration)
    }

    var trimStart: TimeInterval {
        editSettings.trimStart
    }

    var trimEnd: TimeInterval {
        editSettings.effectiveTrimEnd(for: duration)
    }

    var interpolator: ZoomInterpolator {
        ZoomInterpolator(
            keyframes: keyframes,
            springEnabled: editSettings.exportStyle.springCameraEnabled,
            springSettings: editSettings.zoomPreset.motionFX.spring
        )
    }

    var composition: CompositionTimeMap {
        CompositionFactory.singleClip(
            sourcePath: project.videoURL.path,
            sourceIn: trimStart,
            sourceOut: trimEnd
        )
    }

    var renderSettings: CompositionRenderSettings {
        CompositionRenderSettings(
            exportStyle: editSettings.exportStyle,
            zoomPreset: editSettings.zoomPreset,
            cursorEvents: project.cursorEvents,
            clickEvents: project.clickEvents,
            sourceWidth: CGFloat(project.metadata.width),
            sourceHeight: CGFloat(project.metadata.height),
            drawCursor: !project.cursorEvents.isEmpty
        )
    }

    var exportOutputSize: CGSize {
        let source = CGSize(width: project.metadata.width, height: project.metadata.height)
        return editSettings.exportPreset.outputSize(for: source)
    }

    init(project: RecorderProject) {
        self.project = project
        self.keyframes = project.keyframes.sorted { $0.startTime < $1.startTime }
        self.editSettings = project.editSettings
        if editSettings.trimEnd == nil {
            editSettings.trimEnd = project.metadata.duration
        }
        player.replaceCurrentItem(with: AVPlayerItem(url: project.videoURL))
        installTimeObserver()
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }

    func selectKeyframe(_ id: UUID?) {
        selectedKeyframeID = id
    }

    func resolveKeyframeOverlaps() {
        var updated = keyframes
        ZoomKeyframeEditor.resolveOverlaps(&updated)
        keyframes = updated
        persistKeyframes()
    }

    func deleteSelectedKeyframe() {
        guard let selectedKeyframeID else { return }
        keyframes.removeAll { $0.id == selectedKeyframeID }
        self.selectedKeyframeID = nil
        persistKeyframes()
    }

    func moveSelectedKeyframe(by delta: TimeInterval) {
        guard let selectedKeyframeID,
              let index = keyframes.firstIndex(where: { $0.id == selectedKeyframeID })
        else { return }

        keyframes[index] = ZoomKeyframeEditor.moveKeyframe(
            keyframes[index],
            by: delta,
            duration: duration
        )
        ZoomKeyframeEditor.resolveOverlaps(&keyframes)
        persistKeyframes()
    }

    func updateSelectedKeyframeStart(to time: TimeInterval) {
        guard let selectedKeyframeID,
              let index = keyframes.firstIndex(where: { $0.id == selectedKeyframeID })
        else { return }

        keyframes[index] = ZoomKeyframeEditor.resizeKeyframeStart(
            keyframes[index],
            to: time,
            duration: duration
        )
        ZoomKeyframeEditor.resolveOverlaps(&keyframes)
        persistKeyframes()
    }

    func updateSelectedKeyframeEnd(to time: TimeInterval) {
        guard let selectedKeyframeID,
              let index = keyframes.firstIndex(where: { $0.id == selectedKeyframeID })
        else { return }

        keyframes[index] = ZoomKeyframeEditor.resizeKeyframeEnd(
            keyframes[index],
            to: time,
            duration: duration
        )
        ZoomKeyframeEditor.resolveOverlaps(&keyframes)
        persistKeyframes()
    }

    /// - Parameter commit: pass `false` for live drag updates; overlaps are resolved and
    ///   the project saved once, when the drag ends (see `resolveKeyframeOverlaps`).
    ///   Resolving on every tick would permanently trim neighbors the block passes over.
    func updateKeyframe(_ keyframe: ZoomKeyframe, commit: Bool = true) {
        guard let index = keyframes.firstIndex(where: { $0.id == keyframe.id }) else { return }
        keyframes[index] = ZoomKeyframeEditor.clampKeyframe(keyframe, duration: duration)
        guard commit else { return }
        ZoomKeyframeEditor.resolveOverlaps(&keyframes)
        persistKeyframes()
    }

    func updateSelectedKeyframeScale(_ scale: CGFloat) {
        guard let selectedKeyframeID,
              let index = keyframes.firstIndex(where: { $0.id == selectedKeyframeID })
        else { return }
        keyframes[index].scale = max(1.1, min(3.0, scale))
        persistKeyframes()
    }

    func setTrimStart(_ value: TimeInterval) {
        editSettings.trimStart = max(0, min(value, trimEnd - 0.1))
        if playheadTime < editSettings.trimStart {
            seek(to: editSettings.trimStart)
        }
        persistSettings()
    }

    func setTrimEnd(_ value: TimeInterval) {
        editSettings.trimEnd = min(duration, max(value, trimStart + 0.1))
        if playheadTime > trimEnd {
            seek(to: trimEnd)
        }
        persistSettings()
    }

    func applyZoomPreset(_ preset: ZoomPreset, regenerateAuto: Bool = true) {
        editSettings.zoomPreset = preset
        guard regenerateAuto else {
            persistSettings()
            return
        }

        let generator = AutoZoomGenerator(
            settings: preset.settings,
            frameWidth: CGFloat(project.metadata.width),
            frameHeight: CGFloat(project.metadata.height)
        )
        let autoKeyframes = generator.generate(from: project.clickEvents)
        let manualKeyframes = keyframes.filter { $0.source == .manual }
        keyframes = (autoKeyframes + manualKeyframes).sorted { $0.startTime < $1.startTime }
        ZoomKeyframeEditor.resolveOverlaps(&keyframes)
        persistKeyframes()
        persistSettings()
    }

    func addManualZoom(from normalizedRect: CGRect) {
        let keyframe = ZoomKeyframeEditor.makeManualKeyframe(
            at: playheadTime,
            normalizedRect: normalizedRect,
            duration: duration,
            settings: editSettings.zoomPreset.settings
        )
        keyframes.append(keyframe)
        ZoomKeyframeEditor.resolveOverlaps(&keyframes)
        selectedKeyframeID = keyframe.id
        isManualZoomMode = false
        persistKeyframes()
    }

    func seek(to time: TimeInterval) {
        let clamped = max(trimStart, min(time, trimEnd))
        playheadTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
    }

    func togglePlayback() {
        if player.rate > 0 {
            player.pause()
            isPlaying = false
        } else {
            if playheadTime >= trimEnd - 0.05 {
                seek(to: trimStart)
            }
            player.play()
            isPlaying = true
        }
    }

    var isExporting: Bool {
        if case .exporting = state { return true }
        return false
    }

    func export() async {
        guard !isExporting else { return }
        state = .exporting(progress: 0)
        exportProgress = 0

        do {
            persistKeyframes()
            persistSettings()

            let sourceSize = CGSize(width: project.metadata.width, height: project.metadata.height)
            let outputSize = editSettings.exportPreset.outputSize(for: sourceSize)

            try await videoExporter.export(
                sourceURL: project.videoURL,
                outputURL: project.exportURL,
                configuration: ExportConfiguration(
                    keyframes: keyframes,
                    outputSize: outputSize,
                    bitrate: editSettings.exportPreset.targetBitrate(for: outputSize, fps: project.metadata.fps),
                    trimStart: trimStart,
                    trimEnd: trimEnd,
                    exportStyle: editSettings.exportStyle,
                    zoomPreset: editSettings.zoomPreset,
                    cursorEvents: project.cursorEvents,
                    clickEvents: project.clickEvents,
                    drawCursor: !project.cursorEvents.isEmpty
                )
            ) { [weak self] progress in
                Task { @MainActor in
                    // Progress updates can land after the export has already finished.
                    guard let self, self.isExporting else { return }
                    self.exportProgress = progress
                    self.state = .exporting(progress: progress)
                }
            }
            state = .exported
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func revealExportInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([project.exportURL])
    }

    func persistEditSettings() {
        persistSettings()
    }

    private func persistKeyframes() {
        project.keyframes = keyframes
        try? ProjectStore.save(project)
    }

    private func persistSettings() {
        project.editSettings = editSettings
        try? ProjectStore.save(project)
    }

    private func installTimeObserver() {
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let seconds = CMTimeGetSeconds(time)
                self.playheadTime = seconds
                self.isPlaying = self.player.rate > 0
                if seconds >= self.trimEnd, self.player.rate > 0 {
                    self.player.pause()
                    self.isPlaying = false
                    self.seek(to: self.trimEnd)
                }
            }
        }
    }
}
