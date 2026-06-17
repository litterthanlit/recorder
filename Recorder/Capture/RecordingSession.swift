import AppKit
import Foundation

@MainActor
final class RecordingSession: ObservableObject {
    enum State: Equatable {
        case idle
        case recording(startedAt: Date)
        case processing
        case exporting(progress: Double)
        case finished(RecorderProject)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var clickCount: Int = 0
    @Published private(set) var exportProgress: Double = 0

    private let screenRecorder = ScreenRecorder()
    private let inputTracker = InputTracker()
    private let videoExporter = VideoExporter()
    private var elapsedTimer: Timer?
    private var recordingStartTime: TimeInterval = 0
    private var currentProjectID = UUID()
    private var currentBundleURL: URL?

    func start() async {
        guard case .idle = state else { return }
        guard PermissionsManager.shared.hasRequiredPermissions else {
            state = .failed("Screen Recording and Accessibility permissions are required.")
            return
        }

        do {
            try ProjectStore.ensureProjectsDirectory()
            currentProjectID = UUID()
            let bundleURL = ProjectStore.projectsDirectory
                .appendingPathComponent("\(currentProjectID.uuidString).\(RecorderProject.bundleExtension)")
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
            currentBundleURL = bundleURL

            let videoURL = bundleURL.appendingPathComponent("video.mov")
            recordingStartTime = CACurrentMediaTime()

            try await screenRecorder.startRecording(to: videoURL)

            inputTracker.configure(
                startTime: recordingStartTime,
                captureOrigin: screenRecorder.captureOrigin,
                captureSize: CGSize(
                    width: CGFloat(screenRecorder.captureWidth),
                    height: CGFloat(screenRecorder.captureHeight)
                ),
                scaleFactor: screenRecorder.scaleFactor
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
            state = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        guard case .recording = state else { return }

        stopElapsedTimer()
        state = .processing

        do {
            let clickEvents = inputTracker.stop()
            let recordingResult = try await screenRecorder.stopRecording()

            let generator = AutoZoomGenerator(
                frameWidth: CGFloat(recordingResult.width),
                frameHeight: CGFloat(recordingResult.height)
            )
            let keyframes = generator.generate(from: clickEvents)

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
                captureHeight: recordingResult.captureSize.height
            )

            var project = RecorderProject(
                metadata: metadata,
                clickEvents: clickEvents,
                keyframes: keyframes
            )

            try ProjectStore.save(project)

            state = .exporting(progress: 0)
            exportProgress = 0

            let exportURL = project.exportURL
            try await videoExporter.export(
                sourceURL: project.videoURL,
                outputURL: exportURL,
                keyframes: keyframes,
                outputSize: CGSize(width: recordingResult.width, height: recordingResult.height)
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.exportProgress = progress
                    self?.state = .exporting(progress: progress)
                }
            }

            project = RecorderProject(metadata: metadata, clickEvents: clickEvents, keyframes: keyframes)
            state = .finished(project)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func reset() {
        stopElapsedTimer()
        state = .idle
        elapsedTime = 0
        clickCount = 0
        exportProgress = 0
        currentBundleURL = nil
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
