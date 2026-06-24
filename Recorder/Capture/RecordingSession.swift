import AppKit
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
    @Published var preferences = RecordingPreferences.default
    @Published private(set) var availableWindows: [CaptureWindowInfo] = []

    private let screenRecorder = ScreenRecorder()
    private let inputTracker = InputTracker()
    private let countdownOverlay = CountdownOverlay()
    private let presentationMode = PresentationModeManager()
    private var elapsedTimer: Timer?
    private var recordingStartTime: TimeInterval = 0
    private var currentProjectID = UUID()
    private var currentBundleURL: URL?

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

    func start() async {
        guard case .idle = state else { return }
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

        do {
            if preferences.countdownSeconds > 0 {
                state = .countdown(remaining: preferences.countdownSeconds)
                await countdownOverlay.run(seconds: preferences.countdownSeconds)
            }

            try ProjectStore.ensureProjectsDirectory()
            currentProjectID = UUID()
            let bundleURL = ProjectStore.projectsDirectory
                .appendingPathComponent("\(currentProjectID.uuidString).\(RecorderProject.bundleExtension)")
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
            currentBundleURL = bundleURL

            let videoURL = bundleURL.appendingPathComponent("video.mov")
            recordingStartTime = CACurrentMediaTime()

            if preferences.hideChromeDuringRecording {
                presentationMode.enter()
            }

            let recorderOptions = ScreenRecorderOptions(
                captureTarget: preferences.captureTarget,
                windowID: preferences.selectedWindowID,
                showCursor: !preferences.cursorSmoothingEnabled
            )
            try await screenRecorder.startRecording(to: videoURL, options: recorderOptions)

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

            inputTracker.onEvent = { [weak self] _ in
                Task { @MainActor in
                    self?.clickCount += 1
                }
            }

            try inputTracker.start()

            state = .recording(startedAt: Date())
            elapsedTime = 0
            clickCount = 0
            startElapsedTimer()
        } catch {
            presentationMode.exit()
            countdownOverlay.cancel()
            state = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        guard case .recording = state else { return }

        stopElapsedTimer()
        presentationMode.exit()
        state = .processing

        do {
            let trackingResult = inputTracker.stop()
            let recordingResult = try await screenRecorder.stopRecording()

            let generator = AutoZoomGenerator(
                settings: ProjectEditSettings().zoomPreset.settings,
                frameWidth: CGFloat(recordingResult.width),
                frameHeight: CGFloat(recordingResult.height)
            )
            let keyframes = generator.generate(from: trackingResult.clicks)

            var editSettings = ProjectEditSettings()
            editSettings.exportStyle.cursorSmoothingEnabled = preferences.cursorSmoothingEnabled

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

            let editor = ProjectEditor(project: project)
            activeEditor = editor
            state = .editing(project)
        } catch {
            state = .failed(error.localizedDescription)
        }
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

    func markExported(_ project: RecorderProject) {
        state = .finished(project)
    }

    func reset() {
        stopElapsedTimer()
        presentationMode.exit()
        countdownOverlay.cancel()
        state = .idle
        elapsedTime = 0
        clickCount = 0
        exportProgress = 0
        currentBundleURL = nil
        activeEditor = nil
    }

    func revealExportInFinder() {
        guard case let .finished(project) = state else { return }
        NSWorkspace.shared.activateFileViewerSelecting([project.exportURL])
    }

    private func startElapsedTimer() {
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.elapsedTime = CACurrentMediaTime() - self.recordingStartTime
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }
}
