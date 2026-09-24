import AppKit
import AVFoundation
import Foundation
import SwiftUI

/// The part of the editor that undo and redo restore.
struct EditorSnapshot: Equatable {
    var keyframes: [ZoomKeyframe]
    var editSettings: ProjectEditSettings
}

@MainActor
final class ProjectEditor: ObservableObject {
    enum State: Equatable {
        case editing
        case exporting(progress: Double)
        case exported
        case failed(String)
    }

    @Published var project: RecorderProject
    /// Changed only through the editing methods below, so every change can be undone.
    @Published private(set) var keyframes: [ZoomKeyframe]
    @Published private(set) var editSettings: ProjectEditSettings
    @Published var playheadTime: TimeInterval = 0
    @Published var selectedKeyframeID: UUID?
    @Published var isManualZoomMode = false
    @Published var isPlaying = false
    @Published private(set) var state: State = .editing
    @Published private(set) var exportProgress: Double = 0
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var undoActionName: String?
    @Published private(set) var redoActionName: String?

    let player = AVPlayer()
    /// Plays the separate camera track in lockstep with `player` so the preview can
    /// composite the bubble like the export does. `nil` when there is no camera track.
    let cameraPlayer: AVPlayer?

    var hasCameraTrack: Bool {
        cameraPlayer != nil
    }

    private let videoExporter = VideoExporter()
    private let autosaver = ProjectAutosaver()
    private var timeObserver: Any?
    private var terminationObserver: NSObjectProtocol?
    private var history = EditHistory<EditorSnapshot>()
    /// State at the start of a drag or slider gesture that's still in progress.
    private var interaction: (start: EditorSnapshot, actionName: String)?

    private var snapshot: EditorSnapshot {
        EditorSnapshot(keyframes: keyframes, editSettings: editSettings)
    }

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
            drawCursor: !project.cursorEvents.isEmpty,
            camera: editSettings.camera,
            sourcePixelsPerPoint: project.metadata.scaleFactor
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
        if project.hasCameraTrack {
            let cameraPlayer = AVPlayer(playerItem: AVPlayerItem(url: project.cameraURL))
            cameraPlayer.isMuted = true
            self.cameraPlayer = cameraPlayer
        } else {
            cameraPlayer = nil
        }
        if editSettings.trimEnd == nil {
            editSettings.trimEnd = project.metadata.duration
        }
        player.replaceCurrentItem(with: AVPlayerItem(url: project.videoURL))
        installTimeObserver()

        // Edits are saved shortly after they happen; make sure the last one lands.
        let autosaver = self.autosaver
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { _ in
            autosaver.flush()
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        autosaver.flush()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }

    func selectKeyframe(_ id: UUID?) {
        selectedKeyframeID = id
    }

    // MARK: - Editing

    func resolveKeyframeOverlaps() {
        performEdit("Move Zoom") {
            ZoomKeyframeEditor.resolveOverlaps(&keyframes)
        }
    }

    func deleteSelectedKeyframe() {
        guard let selectedKeyframeID else { return }
        performEdit("Delete Zoom") {
            keyframes.removeAll { $0.id == selectedKeyframeID }
        }
        self.selectedKeyframeID = nil
    }

    func moveSelectedKeyframe(by delta: TimeInterval) {
        guard let selectedKeyframeID else { return }
        performEdit("Move Zoom") {
            guard let index = keyframes.firstIndex(where: { $0.id == selectedKeyframeID }) else { return }
            keyframes[index] = ZoomKeyframeEditor.moveKeyframe(keyframes[index], by: delta, duration: duration)
            ZoomKeyframeEditor.resolveOverlaps(&keyframes)
        }
    }

    func updateSelectedKeyframeStart(to time: TimeInterval) {
        guard let selectedKeyframeID else { return }
        performEdit("Resize Zoom") {
            guard let index = keyframes.firstIndex(where: { $0.id == selectedKeyframeID }) else { return }
            keyframes[index] = ZoomKeyframeEditor.resizeKeyframeStart(keyframes[index], to: time, duration: duration)
            ZoomKeyframeEditor.resolveOverlaps(&keyframes)
        }
    }

    func updateSelectedKeyframeEnd(to time: TimeInterval) {
        guard let selectedKeyframeID else { return }
        performEdit("Resize Zoom") {
            guard let index = keyframes.firstIndex(where: { $0.id == selectedKeyframeID }) else { return }
            keyframes[index] = ZoomKeyframeEditor.resizeKeyframeEnd(keyframes[index], to: time, duration: duration)
            ZoomKeyframeEditor.resolveOverlaps(&keyframes)
        }
    }

    /// - Parameter commit: pass `false` for live drag updates inside
    ///   `beginInteractiveEdit` / `endInteractiveEdit`; overlaps are resolved once, when
    ///   the drag ends. Resolving on every tick would trim neighbors the block passes over.
    func updateKeyframe(_ keyframe: ZoomKeyframe, commit: Bool = true) {
        performEdit("Move Zoom", coalescingKey: AnyHashable(keyframe.id), continuous: !commit) {
            guard let index = keyframes.firstIndex(where: { $0.id == keyframe.id }) else { return }
            keyframes[index] = ZoomKeyframeEditor.clampKeyframe(keyframe, duration: duration)
            if commit {
                ZoomKeyframeEditor.resolveOverlaps(&keyframes)
            }
        }
    }

    func updateSelectedKeyframeScale(_ scale: CGFloat) {
        guard let selectedKeyframeID else { return }
        performEdit(
            "Zoom Scale",
            coalescingKey: AnyHashable("scale-\(selectedKeyframeID)"),
            continuous: true
        ) {
            guard let index = keyframes.firstIndex(where: { $0.id == selectedKeyframeID }) else { return }
            keyframes[index].scale = max(1.1, min(3.0, scale))
        }
    }

    func setTrimStart(_ value: TimeInterval) {
        performEdit("Trim", coalescingKey: AnyHashable("trim"), continuous: true) {
            editSettings.trimStart = max(0, min(value, trimEnd - 0.1))
        }
        if playheadTime < editSettings.trimStart {
            seek(to: editSettings.trimStart)
        }
    }

    func setTrimEnd(_ value: TimeInterval) {
        performEdit("Trim", coalescingKey: AnyHashable("trim"), continuous: true) {
            editSettings.trimEnd = min(duration, max(value, trimStart + 0.1))
        }
        if playheadTime > trimEnd {
            seek(to: trimEnd)
        }
    }

    /// Regenerates auto zooms for the preset (manual zooms are kept). Edits to auto zooms
    /// are replaced, which is one undo away.
    func applyZoomPreset(_ preset: ZoomPreset, regenerateAuto: Bool = true) {
        performEdit("Change Zoom Preset") {
            editSettings.zoomPreset = preset
            guard regenerateAuto else { return }

            let generator = AutoZoomGenerator(
                settings: preset.settings,
                frameWidth: CGFloat(project.metadata.width),
                frameHeight: CGFloat(project.metadata.height)
            )
            let autoKeyframes = generator.generate(from: project.clickEvents)
            let manualKeyframes = keyframes.filter { $0.source == .manual }
            keyframes = (autoKeyframes + manualKeyframes).sorted { $0.startTime < $1.startTime }
            ZoomKeyframeEditor.resolveOverlaps(&keyframes)
        }
    }

    func addManualZoom(from normalizedRect: CGRect) {
        let keyframe = ZoomKeyframeEditor.makeManualKeyframe(
            at: playheadTime,
            normalizedRect: normalizedRect,
            duration: duration,
            settings: editSettings.zoomPreset.settings
        )
        performEdit("Add Zoom") {
            keyframes.append(keyframe)
            ZoomKeyframeEditor.resolveOverlaps(&keyframes)
        }
        selectedKeyframeID = keyframe.id
        isManualZoomMode = false
    }

    /// A binding to one edit setting whose changes can be undone.
    /// - Parameter coalesce: merge rapid changes (typing) into one undo step.
    func settingBinding<Value: Equatable>(
        _ keyPath: WritableKeyPath<ProjectEditSettings, Value>,
        actionName: String,
        coalesce: Bool = false
    ) -> Binding<Value> {
        Binding(
            get: { self.editSettings[keyPath: keyPath] },
            set: { newValue in
                guard self.editSettings[keyPath: keyPath] != newValue else { return }
                self.performEdit(actionName, coalescingKey: coalesce ? AnyHashable(keyPath) : nil) {
                    self.editSettings[keyPath: keyPath] = newValue
                }
            }
        )
    }

    // MARK: - Undo

    func undo() {
        endInteractiveEdit()
        guard let previous = history.undo(from: snapshot) else { return }
        restore(previous)
    }

    func redo() {
        endInteractiveEdit()
        guard let next = history.redo(from: snapshot) else { return }
        restore(next)
    }

    /// Starts a continuous edit (dragging a zoom block or trim handle, moving a slider).
    /// Everything changed until `endInteractiveEdit()` becomes one undo step.
    func beginInteractiveEdit(_ actionName: String) {
        guard interaction == nil else { return }
        interaction = (snapshot, actionName)
    }

    /// Finishes a continuous edit: resolves zoom overlaps once and records the undo step.
    func endInteractiveEdit() {
        guard let finished = interaction else { return }
        interaction = nil

        var resolved = keyframes
        ZoomKeyframeEditor.resolveOverlaps(&resolved)
        if resolved != keyframes {
            keyframes = resolved
        }
        recordEdit(from: finished.start, actionName: finished.actionName, coalescingKey: nil)
    }

    /// Applies `change` and records it for undo.
    /// - Parameter continuous: `true` for updates that arrive many times per gesture.
    ///   During an interactive edit they are folded into that edit's single step;
    ///   otherwise they coalesce by `coalescingKey`.
    private func performEdit(
        _ actionName: String,
        coalescingKey: AnyHashable? = nil,
        continuous: Bool = false,
        _ change: () -> Void
    ) {
        if interaction != nil {
            if continuous {
                change()
                persist()
                return
            }
            // A discrete edit while a gesture never reported its end: close it first.
            endInteractiveEdit()
        }

        let before = snapshot
        change()
        recordEdit(from: before, actionName: actionName, coalescingKey: coalescingKey)
    }

    private func recordEdit(from before: EditorSnapshot, actionName: String, coalescingKey: AnyHashable?) {
        guard before != snapshot else { return }
        history.record(
            before,
            actionName: actionName,
            coalescingKey: coalescingKey,
            now: ProcessInfo.processInfo.systemUptime
        )
        persist()
        refreshUndoState()
    }

    private func restore(_ state: EditorSnapshot) {
        keyframes = state.keyframes
        editSettings = state.editSettings
        if let selectedKeyframeID, !keyframes.contains(where: { $0.id == selectedKeyframeID }) {
            self.selectedKeyframeID = nil
        }
        // Keep the playhead inside a restored trim range.
        if playheadTime < trimStart || playheadTime > trimEnd {
            seek(to: playheadTime)
        }
        persist()
        refreshUndoState()
    }

    private func refreshUndoState() {
        canUndo = history.canUndo
        canRedo = history.canRedo
        undoActionName = history.undoActionName
        redoActionName = history.redoActionName
    }

    // MARK: - Playback

    func seek(to time: TimeInterval) {
        let clamped = max(trimStart, min(time, trimEnd))
        playheadTime = clamped
        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: target)
        cameraPlayer?.seek(to: target)
    }

    func togglePlayback() {
        if player.rate > 0 {
            pausePlayback()
        } else {
            if playheadTime >= trimEnd - 0.05 {
                seek(to: trimStart)
            }
            player.play()
            cameraPlayer?.play()
            isPlaying = true
        }
    }

    func pausePlayback() {
        player.pause()
        cameraPlayer?.pause()
        isPlaying = false
    }

    /// Keeps the camera player within a frame or two of the main player during playback.
    private func syncCameraPlayer(to time: CMTime) {
        guard let cameraPlayer else { return }
        let drift = abs(CMTimeGetSeconds(cameraPlayer.currentTime()) - CMTimeGetSeconds(time))
        if player.rate > 0, cameraPlayer.rate == 0 {
            cameraPlayer.play()
        }
        if drift > 0.08 {
            cameraPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
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
            endInteractiveEdit()
            persist()
            autosaver.flush()

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
                    drawCursor: !project.cursorEvents.isEmpty,
                    frameRate: project.metadata.fps,
                    cameraURL: project.hasCameraTrack ? project.cameraURL : nil,
                    camera: editSettings.camera,
                    sourcePixelsPerPoint: project.metadata.scaleFactor
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

    private func persist() {
        project.keyframes = keyframes
        project.editSettings = editSettings
        autosaver.schedule(project)
    }

    private func installTimeObserver() {
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let seconds = CMTimeGetSeconds(time)
                self.playheadTime = seconds
                self.isPlaying = self.player.rate > 0
                if self.isPlaying {
                    self.syncCameraPlayer(to: time)
                } else {
                    self.cameraPlayer?.pause()
                }
                if seconds >= self.trimEnd, self.player.rate > 0 {
                    self.pausePlayback()
                    self.seek(to: self.trimEnd)
                }
            }
        }
    }
}
