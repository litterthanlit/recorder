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
    /// Output time: where the edited video is.
    @Published var playheadTime: TimeInterval = 0
    @Published var selectedKeyframeID: UUID?
    @Published var selectedSegmentID: UUID?
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

    private let autosaver = ProjectAutosaver()
    private var timeObserver: Any?
    private var terminationObserver: NSObjectProtocol?
    private var history = EditHistory<EditorSnapshot>()
    /// The edit the player's current items were built from. Until a change is rebuilt,
    /// it's what the preview must map player time with.
    @Published private(set) var playerTimeline: EditTimeline?
    private var builtAudio: AudioMixSettings?
    private var compositionTask: Task<Void, Never>?
    /// State at the start of a drag or slider gesture that's still in progress.
    private var interaction: (start: EditorSnapshot, actionName: String)?

    private var snapshot: EditorSnapshot {
        EditorSnapshot(keyframes: keyframes, editSettings: editSettings)
    }

    var duration: TimeInterval {
        project.metadata.duration
    }

    /// The edit (always set once the editor exists).
    var timeline: EditTimeline {
        editSettings.timeline ?? editSettings.resolvedTimeline(sourceDuration: duration)
    }

    /// Length of the edited video.
    var outputDuration: TimeInterval {
        timeline.outputDuration
    }

    /// The recording's own time at the playhead (what zooms, clicks and cursor use).
    var playheadSourceTime: TimeInterval {
        timeline.sourceTime(forOutput: playheadTime)
    }

    /// The segment under the playhead.
    var segmentAtPlayhead: EditSegment? {
        timeline.segmentIndex(atOutput: playheadTime).map { timeline.segments[$0] }
    }

    /// Head trim, in source time.
    var trimStart: TimeInterval {
        timeline.trimStart
    }

    /// Tail trim, in source time.
    var trimEnd: TimeInterval {
        timeline.trimEnd
    }

    var interpolator: ZoomInterpolator {
        ZoomInterpolator(
            keyframes: keyframes,
            springEnabled: editSettings.exportStyle.springCameraEnabled,
            springSettings: editSettings.zoomPreset.motionFX.spring
        )
    }

    var renderSettings: CompositionRenderSettings {
        CompositionRenderSettings(project: project, editSettings: editSettings)
    }

    var exportOutputSize: CGSize {
        let source = CGSize(width: project.metadata.width, height: project.metadata.height)
        return editSettings.canvas.pixelSize(source: source)
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
        editSettings.setTimeline(editSettings.resolvedTimeline(sourceDuration: project.metadata.duration))
        // The preview draws the recorded cursor with the system's own cursor images.
        SystemCursorImages.shared.load()
        installTimeObserver()
        scheduleCompositionRebuild(immediately: true)

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
        compositionTask?.cancel()
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

    /// Moves the head trim (source time).
    func setTrimStart(_ value: TimeInterval) {
        editTimeline("Trim", coalescingKey: AnyHashable("trim"), continuous: true) { timeline in
            timeline.setTrimStart(value)
        }
    }

    /// Moves the tail trim (source time).
    func setTrimEnd(_ value: TimeInterval) {
        let duration = self.duration
        editTimeline("Trim", coalescingKey: AnyHashable("trim"), continuous: true) { timeline in
            timeline.setTrimEnd(value, sourceDuration: duration)
        }
    }

    // MARK: - Cuts and speed

    /// Splits the segment under the playhead there. Beeps when the playhead is at an edge.
    func splitAtPlayhead() {
        var updated = timeline
        guard updated.split(atOutput: playheadTime) else {
            NSSound.beep()
            return
        }
        editTimeline("Split") { $0 = updated }
        selectedSegmentID = segmentAtPlayhead?.id
    }

    /// Removes a segment; the rest closes up behind it.
    func deleteSegment(_ id: UUID) {
        var updated = timeline
        guard updated.deleteSegment(id: id) else {
            NSSound.beep()
            return
        }
        editTimeline("Delete Clip") { $0 = updated }
        if selectedSegmentID == id {
            selectedSegmentID = nil
        }
    }

    func setSpeed(_ speed: Double, forSegment id: UUID) {
        editTimeline("Change Speed") { $0.setSpeed(speed, forSegment: id) }
    }

    /// Moves a segment's edges (source time), e.g. dragging a clip's end on the timeline.
    func setSegmentSourceRange(_ id: UUID, start: TimeInterval? = nil, end: TimeInterval? = nil) {
        let duration = self.duration
        editTimeline("Trim Clip", coalescingKey: AnyHashable(id), continuous: true) { timeline in
            if let start {
                timeline.setSourceStart(start, forSegment: id)
            }
            if let end {
                timeline.setSourceEnd(end, forSegment: id, sourceDuration: duration)
            }
        }
    }

    /// Speeds up every stretch where nothing happens on screen input-wise (no clicks,
    /// pointer movement or keys) for at least `minimumIdle` seconds.
    @discardableResult
    func speedUpIdleStretches(speed: Double = 4, minimumIdle: TimeInterval = 2) -> Int {
        let activity = IdleStretchDetector.activityTimes(
            clicks: project.clickEvents,
            cursor: project.cursorEvents,
            keystrokes: project.inputs.keystrokes
        )
        var updated = timeline
        var count = 0
        for segment in timeline.segments where abs(segment.speed - 1) < 1e-9 {
            let stretches = IdleStretchDetector.idleStretches(
                activity: activity,
                within: segment.source,
                minimumIdle: minimumIdle
            )
            for stretch in stretches {
                updated.applySpeed(speed, toSource: stretch)
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        editTimeline("Speed Up Idle Time") { $0 = updated }
        return count
    }

    /// Changes the edit as one undoable step and keeps the legacy trim fields in step.
    private func editTimeline(
        _ actionName: String,
        coalescingKey: AnyHashable? = nil,
        continuous: Bool = false,
        _ change: (inout EditTimeline) -> Void
    ) {
        var updated = timeline
        change(&updated)
        guard updated != timeline else { return }
        performEdit(actionName, coalescingKey: coalescingKey, continuous: continuous) {
            editSettings.setTimeline(updated)
        }
        if playheadTime > outputDuration {
            seek(to: outputDuration)
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
            at: playheadSourceTime,
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
        if let selectedSegmentID, !timeline.segments.contains(where: { $0.id == selectedSegmentID }) {
            self.selectedSegmentID = nil
        }
        // Keep the playhead inside the restored edit.
        if playheadTime > outputDuration {
            seek(to: outputDuration)
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

    /// Moves the playhead to output time `time`.
    func seek(to time: TimeInterval) {
        let clamped = max(0, min(time, outputDuration))
        playheadTime = clamped
        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        cameraPlayer?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Moves the playhead to where source time `time` plays (or where the edit continues
    /// after it, if it was cut).
    func seek(toSource time: TimeInterval) {
        seek(to: timeline.outputTimeClamped(forSource: time))
    }

    func togglePlayback() {
        if player.rate > 0 {
            pausePlayback()
        } else {
            if playheadTime >= outputDuration - 0.05 {
                seek(to: 0)
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
            try await ExportService.export(project) { [weak self] progress in
                // Progress updates can land after the export has already finished.
                guard let self, self.isExporting else { return }
                self.exportProgress = progress
                self.state = .exporting(progress: progress)
            }
            state = .exported
        } catch {
            Log.export.error("Export failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    /// Writes any pending edit to disk now (the window is closing).
    func flushAutosave() {
        endInteractiveEdit()
        persist()
        autosaver.flush()
    }

    func revealExportInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([project.exportURL])
    }

    private func persist() {
        project.keyframes = keyframes
        project.editSettings = editSettings
        autosaver.schedule(project)
        if timeline != playerTimeline || editSettings.audio != builtAudio {
            scheduleCompositionRebuild()
        }
    }

    // MARK: - Player items

    /// Rebuilds what the players play after the edit or audio levels change, shortly
    /// after the last change (a drag rebuilds once it pauses, not on every tick).
    private func scheduleCompositionRebuild(immediately: Bool = false) {
        compositionTask?.cancel()
        compositionTask = Task { [weak self] in
            if !immediately {
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            guard !Task.isCancelled else { return }
            await self?.rebuildComposition()
        }
    }

    private func rebuildComposition() async {
        let timeline = self.timeline
        let audio = editSettings.audio
        guard timeline != playerTimeline || audio != builtAudio else { return }

        // Keep showing the same moment of the recording across the change.
        let playheadSource = (playerTimeline ?? timeline).sourceTime(forOutput: playheadTime)
        let wasPlaying = isPlaying
        do {
            let asset = AVURLAsset(url: project.videoURL)
            let audioTrackCount = try await asset.loadTracks(withMediaType: .audio).count
            let screen = try await TimelineCompositionBuilder.build(
                asset: asset,
                timeline: timeline,
                includeVideo: true,
                audioRoles: project.metadata.resolvedAudioTrackRoles(trackCount: audioTrackCount),
                audio: audio
            )
            var cameraItem: AVPlayerItem?
            if cameraPlayer != nil {
                let camera = try await TimelineCompositionBuilder.build(
                    asset: AVURLAsset(url: project.cameraURL),
                    timeline: timeline,
                    includeVideo: true,
                    audioRoles: nil
                )
                cameraItem = AVPlayerItem(asset: camera.composition)
            }
            // A newer change arrived while building: its rebuild takes over.
            guard !Task.isCancelled, timeline == self.timeline, audio == editSettings.audio else { return }

            let item = AVPlayerItem(asset: screen.composition)
            item.audioMix = screen.audioMix
            item.audioTimePitchAlgorithm = .spectral
            if wasPlaying {
                player.pause()
                cameraPlayer?.pause()
            }
            player.replaceCurrentItem(with: item)
            cameraPlayer?.replaceCurrentItem(with: cameraItem)
            playerTimeline = timeline
            builtAudio = audio
            seek(to: timeline.outputTimeClamped(forSource: playheadSource))
            if wasPlaying {
                player.play()
                cameraPlayer?.play()
            }
        } catch {
            Log.editor.error("Building the preview failed: \(error.localizedDescription, privacy: .public)")
        }
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
                if seconds >= self.outputDuration, self.player.rate > 0 {
                    self.pausePlayback()
                    self.seek(to: self.outputDuration)
                }
            }
        }
    }
}
