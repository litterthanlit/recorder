import AppKit
import CoreMedia
import Foundation

@MainActor
final class RecordingSession: ObservableObject {
    enum State: Equatable {
        case idle
        case countdown(remaining: Int)
        case recording(startedAt: Date)
        case processing
        case editing(RecorderProject)
        case exporting(progress: Double)
        case finished(RecorderProject)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var clickCount: Int = 0
    @Published private(set) var exportProgress: Double = 0
    @Published private(set) var activeEditor: ProjectEditor?
    @Published var preferences = RecordingPreferences.load() {
        didSet { preferences.save() }
    }
    /// A one-line message about the last take (e.g. it was cut short by an error).
    @Published private(set) var notice: String?
    @Published private(set) var availableWindows: [CaptureWindowInfo] = []
    @Published private(set) var availableDisplays: [CaptureDisplayInfo] = []
    @Published private(set) var availableCameras: [MediaDeviceInfo] = []
    @Published private(set) var availableMicrophones: [MediaDeviceInfo] = []

    private let screenRecorder = ScreenRecorder()
    private let cameraMicCapture = CameraMicCapture()
    private let cameraBubble = CameraBubbleOverlay()
    private let cameraPreviewRenderer = CameraPreviewRenderer()
    private let inputTracker = InputTracker()
    private let countdownOverlay = CountdownOverlay()
    private let presentationMode = PresentationModeManager()
    private var elapsedTimer: Timer?
    private var recordingStartTime: TimeInterval = 0
    private var currentProjectID = UUID()
    private var currentBundleURL: URL?
    private var hasStartedInputTracking = false
    private var screenParametersObserver: NSObjectProtocol?

    init() {
        screenRecorder.delegate = self
        cameraMicCapture.delegate = self
        refreshMediaDevices()
        refreshDisplays()
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshDisplays() }
        }
    }

    /// Lists connected displays for the picker. The saved choice is kept even if that
    /// display is unplugged, so it's used again when it comes back; `recordingScreen`
    /// falls back to the main display meanwhile.
    func refreshDisplays() {
        let mainID = CGMainDisplayID()
        availableDisplays = NSScreen.screens.map { screen in
            let id = screen.displayIdentifier
            let name = screen.localizedName
            return CaptureDisplayInfo(displayID: id, name: id == mainID ? "\(name) (Main)" : name)
        }
    }

    /// The screen being recorded in display mode, where the countdown and camera bubble
    /// belong. In window mode the main screen.
    private var recordingScreen: NSScreen? {
        guard preferences.captureTarget == .display else { return NSScreen.main }
        let displayID = CaptureGeometry.resolvedDisplayID(
            preferred: preferences.selectedDisplayID,
            available: NSScreen.screens.map(\.displayIdentifier),
            main: CGMainDisplayID()
        )
        return displayID.flatMap { NSScreen.screen(forDisplayID: $0) } ?? NSScreen.main
    }

    func refreshMediaDevices() {
        availableCameras = MediaDevices.cameras()
        availableMicrophones = MediaDevices.microphones()

        // Saved device IDs can go stale (device unplugged); fall back to the default.
        if preferences.selectedCameraID.map({ id in !availableCameras.contains { $0.id == id } }) ?? true {
            preferences.selectedCameraID = MediaDevices.defaultCameraID()
        }
        if preferences.selectedMicrophoneID.map({ id in !availableMicrophones.contains { $0.id == id } }) ?? true {
            preferences.selectedMicrophoneID = MediaDevices.defaultMicrophoneID()
        }
    }

    /// True while a take is being set up, captured, or saved.
    var isBusy: Bool {
        switch state {
        case .countdown, .recording, .processing:
            return true
        case .idle, .editing, .exporting, .finished, .failed:
            return false
        }
    }

    func refreshWindows() async {
        guard PermissionsManager.shared.hasScreenRecordingPermission else {
            availableWindows = []
            return
        }
        availableWindows = (try? await ScreenRecorder.listCapturableWindows()) ?? []
        if preferences.selectedWindowID == nil {
            preferences.selectedWindowID = availableWindows.first?.windowID
        }
    }

    /// Starts a new take. Works from any state that isn't already recording, so a bad
    /// take can be abandoned without exporting it.
    func start() async {
        switch state {
        case .idle:
            break
        case .failed, .editing, .finished:
            reset()
        case .countdown, .recording, .processing, .exporting:
            return
        }
        notice = nil
        guard PermissionsManager.shared.hasRequiredPermissions else {
            state = .failed("Screen Recording and Accessibility permissions are required.")
            return
        }

        if preferences.captureTarget == .window {
            await refreshWindows()
            guard preferences.selectedWindowID != nil else {
                state = .failed("Select a window to record.")
                return
            }
        }

        if preferences.cameraEnabled {
            await PermissionsManager.shared.requestCameraPermission()
            guard PermissionsManager.shared.hasCameraPermission else {
                state = .failed("Camera permission is required when camera is enabled.")
                return
            }
        }

        if preferences.microphoneEnabled {
            await PermissionsManager.shared.requestMicrophonePermission()
            guard PermissionsManager.shared.hasMicrophonePermission else {
                state = .failed("Microphone permission is required when mic is enabled.")
                return
            }
        }

        // Hide the Dock before the countdown rather than after it: its slide-away animation
        // finishes before capture starts, and the one-time "control System Events"
        // permission prompt appears now instead of holding up the start of the take.
        if preferences.hideChromeDuringRecording {
            presentationMode.enter()
        }

        do {
            if preferences.countdownSeconds > 0 {
                state = .countdown(remaining: preferences.countdownSeconds)
                countdownOverlay.onTick = { [weak self] remaining in
                    guard let self, case .countdown = self.state else { return }
                    self.state = .countdown(remaining: remaining)
                }
                let completed = await countdownOverlay.run(seconds: preferences.countdownSeconds, on: recordingScreen)
                countdownOverlay.onTick = nil
                guard completed else {
                    presentationMode.exit()
                    if case .countdown = state {
                        state = .idle
                    }
                    return
                }
                guard case .countdown = state else {
                    presentationMode.exit()
                    return
                }
            }

            try ProjectStore.ensureProjectsDirectory()
            currentProjectID = UUID()
            let bundleURL = ProjectStore.projectsDirectory
                .appendingPathComponent("\(currentProjectID.uuidString).\(RecorderProject.bundleExtension)")
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
            currentBundleURL = bundleURL

            let videoURL = bundleURL.appendingPathComponent("video.mov")
            hasStartedInputTracking = false
            recordingStartTime = 0

            if preferences.cameraEnabled {
                cameraMicCapture.trackWriter.prepare(
                    outputURL: bundleURL.appendingPathComponent(RecorderProject.cameraFileName)
                )
            }

            try cameraMicCapture.start(
                enableCamera: preferences.cameraEnabled,
                cameraID: preferences.selectedCameraID,
                enableMicrophone: preferences.microphoneEnabled,
                microphoneID: preferences.selectedMicrophoneID,
                cameraBackground: preferences.cameraBackground
            )

            if preferences.cameraEnabled {
                if preferences.cameraBackground.requiresProcessing {
                    cameraBubble.showProcessedPreview(position: preferences.cameraPosition, on: recordingScreen)
                    // Called on the camera queue: build the small preview image there and
                    // only hand the finished image to the main thread.
                    let previewRenderer = cameraPreviewRenderer
                    cameraMicCapture.onCameraFrame = { [weak self] buffer in
                        guard previewRenderer.beginFrame() else { return }
                        guard let image = previewRenderer.makeImage(from: buffer) else {
                            previewRenderer.endFrame()
                            return
                        }
                        Task { @MainActor in
                            self?.cameraBubble.updateProcessedFrame(image)
                            previewRenderer.endFrame()
                        }
                    }
                } else if let previewLayer = cameraMicCapture.previewLayer {
                    cameraBubble.show(previewLayer: previewLayer, position: preferences.cameraPosition, on: recordingScreen)
                }
            }

            var excludeWindowIDs: [UInt32] = []
            if let bubbleID = cameraBubble.windowID {
                excludeWindowIDs.append(bubbleID)
            }

            let recorderOptions = ScreenRecorderOptions(
                captureTarget: preferences.captureTarget,
                windowID: preferences.selectedWindowID,
                displayID: preferences.selectedDisplayID,
                showCursor: !preferences.cursorSmoothingEnabled,
                cropsMenuBar: preferences.hideChromeDuringRecording,
                excludeWindowIDs: excludeWindowIDs,
                enableMicrophone: preferences.microphoneEnabled
            )
            try await screenRecorder.startRecording(to: videoURL, options: recorderOptions)

            inputTracker.onEvent = { [weak self] _ in
                Task { @MainActor in
                    self?.clickCount += 1
                }
            }

            // Click/cursor tracking starts on first video frame so timestamps match PTS.
            state = .recording(startedAt: Date())
            elapsedTime = 0
            clickCount = 0
        } catch {
            cameraMicCapture.trackWriter.cancel()
            teardownCaptureHelpers()
            countdownOverlay.cancel()
            hasStartedInputTracking = false
            state = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        guard case .recording = state else { return }
        await finishRecording(interruption: nil)
    }

    /// Finalizes the current take. When `interruption` is set, capture stopped on its own
    /// (error, window closed, user stopped sharing); whatever was recorded is still saved.
    private func finishRecording(interruption: Error?) async {
        stopElapsedTimer()
        state = .processing

        do {
            let trackingResult = inputTracker.stop()
            hasStartedInputTracking = false
            // Stop capture before tearing down the camera, mic, and presentation mode so
            // the end of the take doesn't show the bubble vanishing or the Dock returning.
            let recordingResult: RecordingResult
            do {
                recordingResult = try await screenRecorder.stopRecording()
            } catch {
                cameraMicCapture.trackWriter.cancel()
                teardownCaptureHelpers()
                throw interruption ?? error
            }
            // Written to camera.mov in the bundle, which the editor picks up by name.
            _ = await cameraMicCapture.trackWriter.finish()
            teardownCaptureHelpers()

            let generator = AutoZoomGenerator(
                settings: ProjectEditSettings().zoomPreset.settings,
                frameWidth: CGFloat(recordingResult.width),
                frameHeight: CGFloat(recordingResult.height)
            )
            let keyframes = generator.generate(from: trackingResult.clicks)

            var editSettings = ProjectEditSettings()
            editSettings.exportStyle.cursorSmoothingEnabled = preferences.cursorSmoothingEnabled
            editSettings.camera.position = preferences.cameraPosition

            let metadata = ProjectMetadata(
                id: currentProjectID,
                createdAt: Date(),
                width: recordingResult.width,
                height: recordingResult.height,
                fps: recordingResult.fps,
                duration: recordingResult.duration,
                scaleFactor: recordingResult.scaleFactor,
                captureOriginX: recordingResult.captureOrigin.x,
                captureOriginY: recordingResult.captureOrigin.y,
                captureWidth: recordingResult.captureSize.width,
                captureHeight: recordingResult.captureSize.height,
                captureTarget: preferences.captureTarget,
                windowTitle: recordingResult.windowTitle,
                appName: recordingResult.appName
            )

            let project = RecorderProject(
                metadata: metadata,
                clickEvents: trackingResult.clicks,
                cursorEvents: trackingResult.cursor,
                keyframes: keyframes,
                editSettings: editSettings
            )

            try ProjectStore.save(project)

            if let interruption {
                notice = "Recording stopped early (\(interruption.localizedDescription)). What was captured was saved."
            }
            let editor = ProjectEditor(project: project)
            activeEditor = editor
            state = .editing(project)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Capture failed mid-take: finalize the file so the take isn't lost, then report.
    private func handleCaptureFailure(_ error: Error) {
        // Start-up errors are thrown from `start()`, and a stop in progress already
        // finalizes the file, so only an active take needs handling here.
        guard case .recording = state else { return }
        Task { await finishRecording(interruption: error) }
    }

    func editor(for projectID: UUID) -> ProjectEditor? {
        guard activeEditor?.project.metadata.id == projectID else { return nil }
        return activeEditor
    }

    func openEditor(for project: RecorderProject) {
        if activeEditor?.project.metadata.id != project.metadata.id {
            activeEditor = ProjectEditor(project: project)
        }
    }

    /// Opens a saved project in the editor (from the Recent list). Ignored mid-take.
    func openProject(_ project: RecorderProject) {
        guard !isBusy else { return }
        notice = nil
        openEditor(for: project)
        state = .editing(project)
    }

    /// Lets go of a project that's about to be moved to the Trash, if it's the one being
    /// edited or shown.
    func forgetProject(id: UUID) {
        guard !isBusy else { return }
        let shownProjectID: UUID?
        switch state {
        case let .editing(project), let .finished(project):
            shownProjectID = project.metadata.id
        case .idle, .countdown, .recording, .processing, .exporting, .failed:
            shownProjectID = nil
        }
        if activeEditor?.project.metadata.id == id || shownProjectID == id {
            reset()
        }
    }

    func markExported(_ project: RecorderProject) {
        // An editor from an earlier take can finish exporting while a new one is recording.
        guard !isBusy else { return }
        state = .finished(project)
    }

    func cancelCountdown() {
        guard case .countdown = state else { return }
        countdownOverlay.onTick = nil
        countdownOverlay.cancel()
        state = .idle
    }

    func reset() {
        stopElapsedTimer()
        teardownCaptureHelpers()
        countdownOverlay.onTick = nil
        countdownOverlay.cancel()
        _ = inputTracker.stop()
        hasStartedInputTracking = false
        state = .idle
        elapsedTime = 0
        clickCount = 0
        exportProgress = 0
        notice = nil
        currentBundleURL = nil
        activeEditor = nil
    }

    func revealExportInFinder() {
        guard case let .finished(project) = state else { return }
        NSWorkspace.shared.activateFileViewerSelecting([project.exportURL])
    }

    private func teardownCaptureHelpers() {
        presentationMode.exit()
        cameraBubble.hide()
        cameraMicCapture.stop()
    }

    /// - Parameter firstFrameHostTime: capture time of video t = 0 on the host clock.
    private func beginInputTrackingAlignedToVideo(firstFrameHostTime: CMTime) {
        guard case .recording = state, !hasStartedInputTracking else { return }
        hasStartedInputTracking = true

        // Use the frame's own capture time rather than "now": the notification reaches the
        // main thread some milliseconds later, which would make every zoom land late.
        // CACurrentMediaTime() is on the same host clock.
        let firstFrameSeconds = CMTimeGetSeconds(firstFrameHostTime)
        recordingStartTime = firstFrameSeconds.isFinite && firstFrameSeconds > 0
            ? firstFrameSeconds
            : CACurrentMediaTime()
        cameraMicCapture.trackWriter.setEpoch(firstFrameHostTime)

        inputTracker.configure(
            startTime: recordingStartTime,
            captureOrigin: screenRecorder.captureOrigin,
            captureSize: CGSize(
                width: CGFloat(screenRecorder.captureWidth),
                height: CGFloat(screenRecorder.captureHeight)
            ),
            scaleFactor: screenRecorder.scaleFactor,
            trackCursor: preferences.cursorSmoothingEnabled
        )

        do {
            try inputTracker.start()
            startElapsedTimer()
        } catch {
            // Capture is already running; save it (without clicks) rather than leaving
            // the recorder running with nothing tracking it.
            hasStartedInputTracking = false
            handleCaptureFailure(error)
        }
    }

    private func startElapsedTimer() {
        stopElapsedTimer()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.recordingStartTime > 0 else { return }
                self.elapsedTime = CACurrentMediaTime() - self.recordingStartTime
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }
}

extension RecordingSession: ScreenRecorderDelegate {
    nonisolated func screenRecorder(_ recorder: ScreenRecorder, didReceiveFirstFrameAt hostTime: CMTime) {
        Task { @MainActor in
            self.beginInputTrackingAlignedToVideo(firstFrameHostTime: hostTime)
        }
    }

    nonisolated func screenRecorder(_ recorder: ScreenRecorder, didWriteFrameAt time: TimeInterval) {
        // Frame timing is driven by the writer; elapsed UI uses the shared epoch.
    }

    nonisolated func screenRecorder(_ recorder: ScreenRecorder, didFailWith error: Error) {
        Task { @MainActor in
            self.handleCaptureFailure(error)
        }
    }
}

extension RecordingSession: CameraMicCaptureDelegate {
    nonisolated func cameraMicCapture(
        _ capture: CameraMicCapture,
        didOutputAudioSampleBuffer sampleBuffer: CMSampleBuffer,
        hostTime: CMTime
    ) {
        screenRecorder.appendAudioSampleBuffer(sampleBuffer, hostTime: hostTime)
    }

    nonisolated func cameraMicCapture(_ capture: CameraMicCapture, didFailWith error: Error) {
        Task { @MainActor in
            self.handleCaptureFailure(error)
        }
    }
}
