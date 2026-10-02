import AppKit
import AVFoundation
import Foundation
import SwiftUI

/// What's selected in the editor: one item on the timeline.
enum EditorSelection: Equatable {
    case clip(UUID)
    case zoom(UUID)
    case text(UUID)
    case blur(UUID)
    case cameraMove(UUID)
}

/// The playhead, published on its own so the ticks during playback (20 a second) only
/// redraw the views that show it, not the whole editor. Main thread only.
final class EditorPlayback: ObservableObject {
    /// Output time: where the edited video is.
    @Published var time: TimeInterval = 0
    @Published var isPlaying = false
}

@MainActor
final class ProjectEditor: ObservableObject {
    enum State: Equatable {
        case editing
        case exporting(progress: Double)
        case exported(URL)
        case failed(String)
    }

    @Published var project: RecorderProject
    /// Changed only through the editing methods below, so every change can be undone.
    @Published private(set) var keyframes: [ZoomKeyframe]
    @Published private(set) var editSettings: ProjectEditSettings
    @Published var selection: EditorSelection?
    /// Dragging over the canvas picks the area for a new zoom.
    @Published var isManualZoomMode = false
    /// Drawing the part of the recording to keep (the crop) over the whole recording.
    @Published var isCropMode = false
    /// The canvas shows the whole recording with the selected zoom's focus to drag.
    @Published var isEditingZoomFocus = false
    @Published var isExportSheetPresented = false
    let playback = EditorPlayback()
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
    private var exportTask: Task<Void, Never>?
    /// State at the start of a drag or slider gesture that's still in progress.
    private var interaction: (start: EditorSnapshot, actionName: String)?

    private var snapshot: EditorSnapshot {
        EditorSnapshot(keyframes: keyframes, editSettings: editSettings)
    }

    /// Output time: where the edited video is.
    var playheadTime: TimeInterval {
        get { playback.time }
        set { playback.time = newValue }
    }

    var isPlaying: Bool {
        get { playback.isPlaying }
        set { playback.isPlaying = newValue }
    }

    var selectedKeyframeID: UUID? {
        get {
            if case let .zoom(id)? = selection { return id }
            return nil
        }
        set { setSelection(newValue.map { EditorSelection.zoom($0) }, clearing: selectedKeyframeID.map { EditorSelection.zoom($0) }) }
    }

    var selectedSegmentID: UUID? {
        get {
            if case let .clip(id)? = selection { return id }
            return nil
        }
        set { setSelection(newValue.map { EditorSelection.clip($0) }, clearing: selectedSegmentID.map { EditorSelection.clip($0) }) }
    }

    var selectedTextID: UUID? {
        if case let .text(id)? = selection { return id }
        return nil
    }

    var selectedBlurID: UUID? {
        if case let .blur(id)? = selection { return id }
        return nil
    }

    var selectedCameraMoveID: UUID? {
        if case let .cameraMove(id)? = selection { return id }
        return nil
    }

    var selectedCameraMove: CameraMove? {
        selectedCameraMoveID.flatMap { id in editSettings.cameraMoves.first { $0.id == id } }
    }

    var selectedKeyframe: ZoomKeyframe? {
        selectedKeyframeID.flatMap { id in keyframes.first { $0.id == id } }
    }

    var selectedText: TextOverlay? {
        selectedTextID.flatMap { id in editSettings.textOverlays.first { $0.id == id } }
    }

    var selectedBlur: BlurRegion? {
        selectedBlurID.flatMap { id in editSettings.blurRegions.first { $0.id == id } }
    }

    var selectedSegment: EditSegment? {
        selectedSegmentID.flatMap { id in timeline.segments.first { $0.id == id } }
    }

    /// Setting `nil` through one kind's ID only clears the selection if it was that kind.
    private func setSelection(_ newValue: EditorSelection?, clearing current: EditorSelection?) {
        if let newValue {
            select(newValue)
        } else if selection == current {
            select(nil)
        }
    }

    func select(_ newSelection: EditorSelection?) {
        guard selection != newSelection else { return }
        selection = newSelection
        if case .zoom? = newSelection { return }
        isEditingZoomFocus = false
    }

    var duration: TimeInterval {
        project.metadata.duration
    }

    /// The recording's name, or its automatic title.
    var displayName: String {
        project.metadata.name ?? ProjectSummary.title(for: project.metadata)
    }

    /// Names the recording (an empty name goes back to the automatic title).
    func rename(to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName = trimmed.isEmpty ? nil : trimmed
        guard newName != project.metadata.name else { return }
        project.metadata.name = newName
        do {
            try ProjectStore.rename(bundleURL: project.bundleURL, to: trimmed)
        } catch {
            Log.editor.error("Rename failed: \(error.localizedDescription, privacy: .public)")
        }
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
            springSettings: editSettings.zoomPreset.motionFX.spring,
            base: editSettings.cropBase,
            path: editSettings.cropPath
        )
    }

    var renderSettings: CompositionRenderSettings {
        CompositionRenderSettings(project: project, editSettings: editSettings)
    }

    var exportOutputSize: CGSize {
        editSettings.canvasPixelSize(source: sourceSize)
    }

    /// The recording's size in pixels.
    var sourceSize: CGSize {
        CGSize(width: project.metadata.width, height: project.metadata.height)
    }

    /// The recording's size once cropped.
    var contentSize: CGSize {
        editSettings.contentSize(source: sourceSize)
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

    /// Opens with an undo history already in place: AI agents' edits made while the take
    /// was closed, so they can still be undone here.
    convenience init(project: RecorderProject, history: EditHistory<EditorSnapshot>) {
        self.init(project: project)
        self.history = history
        refreshUndoState()
    }

    deinit {
        compositionTask?.cancel()
        exportTask?.cancel()
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

    // MARK: - Selection

    /// Deletes whatever is selected (a clip closes up the gap).
    func deleteSelection() {
        switch selection {
        case let .clip(id)?: deleteSegment(id)
        case .zoom?: deleteSelectedKeyframe()
        case let .text(id)?: deleteText(id)
        case let .blur(id)?: deleteBlur(id)
        case let .cameraMove(id)?: deleteCameraMove(id)
        case nil: NSSound.beep()
        }
    }

    /// Moves the selected zoom, text or blur by `delta` seconds.
    func nudgeSelection(by delta: TimeInterval) {
        switch selection {
        case .zoom?:
            moveSelectedKeyframe(by: delta)
        case let .text(id)?:
            updateText(id, actionName: "Move Text", coalesce: true) { $0.span = shifted($0.span, by: delta) }
        case let .blur(id)?:
            updateBlur(id, actionName: "Move Blur", coalesce: true) { $0.span = shifted($0.span, by: delta) }
        case let .cameraMove(id)?:
            updateCameraMove(id, actionName: "Move 3D Move", coalesce: true) { $0.span = shifted($0.span, by: delta) }
        case .clip?, nil:
            NSSound.beep()
        }
    }

    /// `span` moved by `delta`, kept inside the recording.
    func shifted(_ span: TimeSpan, by delta: TimeInterval) -> TimeSpan {
        let length = span.duration
        let start = min(max(span.start + delta, 0), max(0, duration - length))
        return TimeSpan(start: start, end: start + length)
    }

    // MARK: - Text and blur

    /// Adds a caption at the playhead and selects it.
    func addText() {
        let start = playheadSourceTime
        let end = min(duration, start + TextOverlay.defaultDuration)
        guard end - start > 0.1 else {
            NSSound.beep()
            return
        }
        let overlay = TextOverlay(text: "Your text", span: TimeSpan(start: start, end: end))
        performEdit("Add Text") {
            editSettings.textOverlays.append(overlay)
        }
        select(.text(overlay.id))
    }

    /// Changes one text overlay as an undoable edit.
    /// - Parameters:
    ///   - coalesce: merge rapid changes (typing, nudging) into one undo step.
    ///   - continuous: a live drag update inside `beginInteractiveEdit`.
    func updateText(
        _ id: UUID,
        actionName: String = "Edit Text",
        coalesce: Bool = false,
        continuous: Bool = false,
        _ change: (inout TextOverlay) -> Void
    ) {
        guard let index = editSettings.textOverlays.firstIndex(where: { $0.id == id }) else { return }
        var updated = editSettings.textOverlays[index]
        change(&updated)
        updated.center = TextOverlay.clampedCenter(updated.center)
        guard updated != editSettings.textOverlays[index] else { return }
        performEdit(actionName, coalescingKey: coalesce ? AnyHashable("text-\(id)-\(actionName)") : nil, continuous: continuous) {
            if let current = editSettings.textOverlays.firstIndex(where: { $0.id == id }) {
                editSettings.textOverlays[current] = updated
            }
        }
    }

    func deleteText(_ id: UUID) {
        performEdit("Delete Text") {
            editSettings.textOverlays.removeAll { $0.id == id }
        }
        if selectedTextID == id {
            select(nil)
        }
    }

    /// Adds a blur over the middle of the frame at the playhead and selects it, ready to
    /// be moved over what should be hidden.
    func addBlur() {
        let start = playheadSourceTime
        let end = min(duration, start + 3)
        guard end - start > 0.1 else {
            NSSound.beep()
            return
        }
        let region = BlurRegion(
            span: TimeSpan(start: start, end: end),
            rect: CGRect(x: 0.35, y: 0.42, width: 0.3, height: 0.16)
        )
        performEdit("Add Blur") {
            editSettings.blurRegions.append(region)
        }
        select(.blur(region.id))
    }

    func updateBlur(
        _ id: UUID,
        actionName: String = "Edit Blur",
        coalesce: Bool = false,
        continuous: Bool = false,
        _ change: (inout BlurRegion) -> Void
    ) {
        guard let index = editSettings.blurRegions.firstIndex(where: { $0.id == id }) else { return }
        var updated = editSettings.blurRegions[index]
        change(&updated)
        updated.rect = BlurRegion.clampedRect(updated.rect)
        guard updated != editSettings.blurRegions[index] else { return }
        performEdit(actionName, coalescingKey: coalesce ? AnyHashable("blur-\(id)-\(actionName)") : nil, continuous: continuous) {
            if let current = editSettings.blurRegions.firstIndex(where: { $0.id == id }) {
                editSettings.blurRegions[current] = updated
            }
        }
    }

    func deleteBlur(_ id: UUID) {
        performEdit("Delete Blur") {
            editSettings.blurRegions.removeAll { $0.id == id }
        }
        if selectedBlurID == id {
            select(nil)
        }
    }

    /// Sets a text or blur item's span (source time), e.g. from a timeline drag.
    func setSpan(_ span: TimeSpan, for item: EditorSelection, continuous: Bool) {
        let clamped = TimeSpan(
            start: min(max(span.start, 0), duration),
            end: min(max(span.end, 0), duration)
        )
        guard clamped.duration >= 0.1 else { return }
        switch item {
        case let .text(id):
            updateText(id, actionName: "Move Text", continuous: continuous) { $0.span = clamped }
        case let .blur(id):
            updateBlur(id, actionName: "Move Blur", continuous: continuous) { $0.span = clamped }
        case let .cameraMove(id):
            updateCameraMove(id, actionName: "Move 3D Move", continuous: continuous) { $0.span = clamped }
        case .clip, .zoom:
            break
        }
    }

    // MARK: - 3D moves

    /// Adds a 3D move of `kind` at the playhead and selects it.
    func addCameraMove(_ kind: CameraMoveKind) {
        let start = playheadSourceTime
        let end = min(duration, start + kind.defaultDuration)
        guard end - start > 0.2 else {
            NSSound.beep()
            return
        }
        let move = CameraMove(kind: kind, span: TimeSpan(start: start, end: end))
        performEdit("Add 3D Move") {
            editSettings.cameraMoves.append(move)
        }
        select(.cameraMove(move.id))
    }

    func updateCameraMove(
        _ id: UUID,
        actionName: String = "Edit 3D Move",
        coalesce: Bool = false,
        continuous: Bool = false,
        _ change: (inout CameraMove) -> Void
    ) {
        guard let index = editSettings.cameraMoves.firstIndex(where: { $0.id == id }) else { return }
        var updated = editSettings.cameraMoves[index]
        change(&updated)
        updated.intensity = min(max(updated.intensity, 0), 1)
        guard updated != editSettings.cameraMoves[index] else { return }
        performEdit(actionName, coalescingKey: coalesce ? AnyHashable("move-\(id)-\(actionName)") : nil, continuous: continuous) {
            if let current = editSettings.cameraMoves.firstIndex(where: { $0.id == id }) {
                editSettings.cameraMoves[current] = updated
            }
        }
    }

    func deleteCameraMove(_ id: UUID) {
        performEdit("Delete 3D Move") {
            editSettings.cameraMoves.removeAll { $0.id == id }
        }
        if selectedCameraMoveID == id {
            select(nil)
        }
    }

    // MARK: - Look

    /// Applies a saved or built-in look. Auto zooms follow its zoom preset.
    func applyLook(_ preset: StylePreset) {
        let zoomChanged = preset.zoomPreset != editSettings.zoomPreset
        performEdit("Apply Look") {
            preset.apply(to: &editSettings)
            if zoomChanged {
                regenerateAutoZooms(for: preset.zoomPreset)
            }
        }
    }

    /// Copies a picture into the project and uses it as the background.
    func useBackgroundImage(at url: URL) {
        do {
            let name = try ProjectStore.importBackgroundImage(from: url, into: project.bundleURL)
            performEdit("Background Image") {
                editSettings.exportStyle.background.kind = .image
                editSettings.exportStyle.background.imageFileName = name
            }
        } catch {
            Log.editor.error("Couldn't use the background image: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
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
        select(nil)
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
    func updateKeyframe(_ keyframe: ZoomKeyframe, commit: Bool = true, actionName: String = "Move Zoom") {
        performEdit(actionName, coalescingKey: AnyHashable(keyframe.id), continuous: !commit) {
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
            let range = ZoomKeyframeEditor.focusScaleRange
            keyframes[index].scale = max(range.lowerBound, min(range.upperBound, scale))
        }
    }

    /// Adds a zoom over `span` (source time), pointing where the preview looks now, and
    /// selects it (dragging on the zoom track).
    func addZoom(over span: TimeSpan) {
        let length = span.duration
        guard length >= ZoomKeyframeEditor.minimumSpan else { return }
        let crop = interpolator.cropRect(at: span.start)
        let center = CGPoint(x: crop.x + crop.width / 2, y: crop.y + crop.height / 2)
        let settings = editSettings.zoomPreset.settings
        let keyframe = ZoomKeyframeEditor.keyframe(
            ZoomKeyframe(
                startTime: span.start,
                peakTime: span.start + min(settings.easeInDuration, length / 3),
                endTime: span.end,
                center: center,
                scale: settings.zoomScale,
                source: .manual
            ),
            movingFocusTo: center,
            base: editSettings.cropBase(at: span.start)
        )
        performEdit("Add Zoom") {
            keyframes.append(ZoomKeyframeEditor.clampKeyframe(keyframe, duration: duration))
            ZoomKeyframeEditor.resolveOverlaps(&keyframes)
        }
        select(.zoom(keyframe.id))
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
        let splitTime = timeline.sourceTime(forOutput: playheadTime)
        guard updated.split(atOutput: playheadTime) else {
            NSSound.beep()
            return
        }
        editTimeline("Split") { $0 = updated }
        // Ramps reshape both halves, which moves the split in output time: stay on it.
        if updated.hasSpeedRamps {
            seek(toSource: splitTime)
        }
        if let segment = segmentAtPlayhead {
            select(.clip(segment.id))
        }
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
            select(nil)
        }
    }

    func setSpeed(_ speed: Double, forSegment id: UUID) {
        editTimeline("Change Speed", coalescingKey: AnyHashable("speed-\(id)"), continuous: true) {
            $0.setSpeed(speed, forSegment: id)
        }
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
            if regenerateAuto {
                regenerateAutoZooms(for: preset)
            }
        }
    }

    /// Replaces the auto zooms with fresh ones for `preset`; manual zooms stay.
    private func regenerateAutoZooms(for preset: ZoomPreset) {
        keyframes = ZoomKeyframeEditor.replacingAutoZooms(
            in: keyframes,
            clicks: project.clickEvents,
            preset: preset,
            frameSize: CGSize(width: project.metadata.width, height: project.metadata.height)
        )
        if let selectedKeyframeID, !keyframes.contains(where: { $0.id == selectedKeyframeID }) {
            select(nil)
        }
    }

    func addManualZoom(from normalizedRect: CGRect) {
        let keyframe = ZoomKeyframeEditor.makeManualKeyframe(
            at: playheadSourceTime,
            normalizedRect: normalizedRect,
            duration: duration,
            settings: editSettings.zoomPreset.settings,
            base: editSettings.cropBase(at: playheadSourceTime)
        )
        performEdit("Add Zoom") {
            keyframes.append(keyframe)
            ZoomKeyframeEditor.resolveOverlaps(&keyframes)
        }
        select(.zoom(keyframe.id))
        isManualZoomMode = false
    }

    /// A binding to one edit setting whose changes can be undone.
    /// - Parameter coalesce: merge rapid changes (typing) into one undo step.
    /// - Parameter continuous: for sliders: changes fold into the interactive edit a
    ///   slider starts with `beginInteractiveEdit`, and otherwise coalesce.
    func settingBinding<Value: Equatable>(
        _ keyPath: WritableKeyPath<ProjectEditSettings, Value>,
        actionName: String,
        coalesce: Bool = false,
        continuous: Bool = false
    ) -> Binding<Value> {
        Binding(
            get: { self.editSettings[keyPath: keyPath] },
            set: { newValue in
                guard self.editSettings[keyPath: keyPath] != newValue else { return }
                self.performEdit(
                    actionName,
                    coalescingKey: coalesce || continuous ? AnyHashable(keyPath) : nil,
                    continuous: continuous
                ) {
                    self.editSettings[keyPath: keyPath] = newValue
                }
            }
        )
    }

    // MARK: - Motion

    /// Whether sped-up parts ease in and out instead of jumping speed.
    var smoothSpeedChanges: Bool {
        timeline.hasSpeedRamps
    }

    func setSmoothSpeedChanges(_ on: Bool) {
        let ramp: TimeInterval? = on ? SpeedRamp.defaultRamp : nil
        editTimeline(on ? "Smooth Speed Changes" : "Sharp Speed Changes") { $0.speedRamp = ramp }
    }

    // MARK: - Crop

    /// Shows only `rect` of the recording (normalized, bottom-left origin), holding
    /// still, or all of it for `nil`, and leaves crop mode.
    func setSourceCrop(_ rect: CGRect?) {
        let crop = rect.flatMap { SourceCrop.sanitized($0) }
        isCropMode = false
        guard crop != editSettings.sourceCrop || editSettings.cropPath != nil else { return }
        performEdit(crop == nil ? "Remove Crop" : "Crop") {
            editSettings.sourceCrop = crop
            editSettings.cropPath = nil
        }
    }

    /// Crops to `app`'s window, following it as it moves (see `WindowCrop`), and leaves
    /// crop mode. Returns false when the window never showed in the recording.
    @discardableResult
    func cropToWindow(of app: String) -> Bool {
        guard let window = WindowCrop.following(app, in: project.inputs.appFocus, duration: duration) else { return false }
        isCropMode = false
        guard window.crop != editSettings.sourceCrop || window.path != editSettings.cropPath else { return true }
        performEdit("Crop to \(app)") {
            editSettings.sourceCrop = window.crop
            editSettings.cropPath = window.path
        }
        return true
    }

    // MARK: - Outside edits (AI agents)

    /// The edit as it is now, including changes not saved yet.
    var currentSnapshot: EditorSnapshot {
        snapshot
    }

    /// Applies an outside edit (an AI agent's) as one undo step named `actionName`. The
    /// preview, timeline and inspector follow as they do for any edit.
    func applyExternalEdit(_ actionName: String, _ change: (inout EditorSnapshot) throws -> Void) rethrows {
        endInteractiveEdit()
        var updated = snapshot
        try change(&updated)
        updated.keyframes.sort { $0.startTime < $1.startTime }
        ZoomKeyframeEditor.resolveOverlaps(&updated.keyframes)
        updated.keyframes.sort { $0.startTime < $1.startTime }
        guard updated != snapshot else { return }
        performEdit(actionName) {
            keyframes = updated.keyframes
            editSettings = updated.editSettings
        }
        if !selectionExists {
            select(nil)
        }
        if playheadTime > outputDuration {
            seek(to: outputDuration)
        }
    }

    /// Undoes the last step if an agent made it (any step with `force`). Returns the
    /// step's name, or `nil` when there was nothing it may undo.
    @discardableResult
    func undoAgentEdit(force: Bool) -> String? {
        endInteractiveEdit()
        guard let name = undoActionName, force || name.hasPrefix(AgentEdits.actionPrefix) else { return nil }
        undo()
        return name
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
        if !selectionExists {
            select(nil)
        }
        // Keep the playhead inside the restored edit.
        if playheadTime > outputDuration {
            seek(to: outputDuration)
        }
        persist()
        refreshUndoState()
    }

    /// Whether the selected item is still there (after undo, say).
    private var selectionExists: Bool {
        switch selection {
        case let .clip(id)?: return timeline.segments.contains { $0.id == id }
        case let .zoom(id)?: return keyframes.contains { $0.id == id }
        case let .text(id)?: return editSettings.textOverlays.contains { $0.id == id }
        case let .blur(id)?: return editSettings.blurRegions.contains { $0.id == id }
        case let .cameraMove(id)?: return editSettings.cameraMoves.contains { $0.id == id }
        case nil: return true
        }
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

    /// Moves the playhead by whole output frames.
    func step(frames: Int) {
        pausePlayback()
        let frameDuration = 1 / Double(max(project.metadata.fps, 1))
        seek(to: playheadTime + Double(frames) * frameDuration)
    }

    func step(seconds: Double) {
        pausePlayback()
        seek(to: playheadTime + seconds)
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

    /// Exports with `options` to `destination` (see `ExportService`). Replaces a running
    /// export's result only once it finishes; `cancelExport()` stops it.
    func export(options: ExportOptions, to destination: URL) {
        guard !isExporting else { return }
        endInteractiveEdit()
        persist()
        autosaver.flush()
        state = .exporting(progress: 0)
        exportProgress = 0
        let project = self.project
        exportTask = Task { [weak self] in
            do {
                let url = try await ExportService.export(project, options: options, to: destination) { progress in
                    // Progress updates can land after the export has already finished.
                    guard let self, self.isExporting else { return }
                    self.exportProgress = progress
                    self.state = .exporting(progress: progress)
                }
                self?.state = .exported(url)
            } catch is CancellationError {
                self?.state = .editing
            } catch {
                Log.export.error("Export failed: \(error.localizedDescription, privacy: .public)")
                self?.state = .failed(error.localizedDescription)
            }
            self?.exportTask = nil
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    /// Back to editing after a finished or failed export.
    func dismissExportResult() {
        if !isExporting {
            state = .editing
        }
    }

    /// The file the last export wrote, if it's still there.
    var latestExportURL: URL? {
        if case let .exported(url) = state, FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return project.latestExportURL
    }

    /// Writes any pending edit to disk now (the window is closing), and removes
    /// background pictures that were replaced (undo can't bring them back any more).
    func flushAutosave() {
        endInteractiveEdit()
        persist()
        autosaver.flush()
        ProjectStore.removeUnusedBackgroundImages(
            in: project.bundleURL,
            keeping: editSettings.exportStyle.background.imageFileName
        )
    }

    func revealExportInFinder() {
        guard let url = latestExportURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
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
