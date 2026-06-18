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
    @Published var playheadTime: TimeInterval = 0
    @Published var selectedKeyframeID: UUID?
    @Published var isManualZoomMode = false
    @Published private(set) var state: State = .editing
    @Published private(set) var exportProgress: Double = 0

    let player = AVPlayer()

    private let videoExporter = VideoExporter()
    private var timeObserver: Any?

    var duration: TimeInterval {
        project.metadata.duration
    }

    var interpolator: ZoomInterpolator {
        ZoomInterpolator(keyframes: keyframes)
    }

    init(project: RecorderProject) {
        self.project = project
        self.keyframes = project.keyframes.sorted { $0.startTime < $1.startTime }
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

    func updateKeyframe(_ keyframe: ZoomKeyframe) {
        guard let index = keyframes.firstIndex(where: { $0.id == keyframe.id }) else { return }
        keyframes[index] = ZoomKeyframeEditor.clampKeyframe(keyframe, duration: duration)
        ZoomKeyframeEditor.resolveOverlaps(&keyframes)
        persistKeyframes()
    }

    func addManualZoom(from normalizedRect: CGRect) {
        let keyframe = ZoomKeyframeEditor.makeManualKeyframe(
            at: playheadTime,
            normalizedRect: normalizedRect,
            duration: duration
        )
        keyframes.append(keyframe)
        ZoomKeyframeEditor.resolveOverlaps(&keyframes)
        selectedKeyframeID = keyframe.id
        isManualZoomMode = false
        persistKeyframes()
    }

    func seek(to time: TimeInterval) {
        let clamped = max(0, min(time, duration))
        playheadTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
    }

    func togglePlayback() {
        if player.rate > 0 {
            player.pause()
        } else {
            if playheadTime >= duration - 0.05 {
                seek(to: 0)
            }
            player.play()
        }
    }

    func export() async {
        state = .exporting(progress: 0)
        exportProgress = 0

        do {
            persistKeyframes()
            let outputSize = CGSize(
                width: project.metadata.width,
                height: project.metadata.height
            )
            try await videoExporter.export(
                sourceURL: project.videoURL,
                outputURL: project.exportURL,
                keyframes: keyframes,
                outputSize: outputSize
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.exportProgress = progress
                    self?.state = .exporting(progress: progress)
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

    private func persistKeyframes() {
        project.keyframes = keyframes
        try? ProjectStore.save(project)
    }

    private func installTimeObserver() {
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                self?.playheadTime = CMTimeGetSeconds(time)
            }
        }
    }
}
