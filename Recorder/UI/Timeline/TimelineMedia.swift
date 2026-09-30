import AVFoundation
import CoreGraphics
import CoreMedia
import SwiftUI

/// Thumbnails and audio levels of a recording for the timeline, loaded in the background
/// when the editor opens. Both are in source time, so they stay valid through any edit.
@MainActor
final class TimelineMedia: ObservableObject {
    /// Audio peaks, `Waveform.peaksPerSecond` per second of the recording.
    @Published private(set) var peaks: [Float] = []
    /// Thumbnails by index: index `i` shows source time (i + 0.5) × `thumbnailInterval`.
    @Published private(set) var thumbnails: [Int: CGImage] = [:]
    /// Whether loading finished (so an empty waveform means no audio).
    @Published private(set) var isLoaded = false
    private(set) var thumbnailInterval: TimeInterval = 1
    /// Width over height of the recording.
    private(set) var aspect: CGFloat = 16.0 / 9.0

    private var loadedProjectID: UUID?

    /// At most this many thumbnails per recording.
    private static let maximumThumbnails = 160

    func load(project: RecorderProject) async {
        guard loadedProjectID != project.metadata.id else { return }
        loadedProjectID = project.metadata.id
        isLoaded = false
        peaks = []
        thumbnails = [:]

        let duration = max(project.metadata.duration, 0.1)
        aspect = CGFloat(project.metadata.width) / CGFloat(max(project.metadata.height, 1))
        thumbnailInterval = max(1, duration / Double(Self.maximumThumbnails))

        let url = project.videoURL
        async let levels = Self.loadPeaks(url: url)
        await loadThumbnails(url: url, duration: duration)
        peaks = await levels
        isLoaded = true
    }

    /// The loaded thumbnail closest to `sourceTime`.
    func thumbnail(near sourceTime: TimeInterval) -> CGImage? {
        let index = max(0, Int(sourceTime / thumbnailInterval))
        if let image = thumbnails[index] {
            return image
        }
        for distance in 1...4 {
            if let image = thumbnails[index - distance] ?? thumbnails[index + distance] {
                return image
            }
        }
        return nil
    }

    private func loadThumbnails(url: URL, duration: TimeInterval) async {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.maximumSize = CGSize(width: 200, height: 120)
        generator.appliesPreferredTrackTransform = true
        // Screen recordings change rarely; any nearby frame will do and is much faster.
        let tolerance = CMTime(seconds: thumbnailInterval / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let count = max(1, Int((duration / thumbnailInterval).rounded(.up)))
        var batch: [Int: CGImage] = [:]
        for index in 0..<count {
            if Task.isCancelled {
                return
            }
            let time = CMTime(seconds: (Double(index) + 0.5) * thumbnailInterval, preferredTimescale: 600)
            if let image = (try? await generator.image(at: time))?.image {
                batch[index] = image
            }
            // Publish in small batches so the strip fills in without redrawing per frame.
            if batch.count >= 8 || index == count - 1 {
                thumbnails.merge(batch) { _, new in new }
                batch.removeAll()
            }
        }
    }

    /// Peak levels of all audio tracks mixed to mono; empty without audio.
    nonisolated private static func loadPeaks(url: URL) async -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
              let reader = try? AVAssetReader(asset: asset)
        else { return [] }

        let sampleRate = 8_000.0
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        let bucketSize = max(1, Int(sampleRate / Waveform.peaksPerSecond))
        var peaks: [Float] = []
        var current: Float = 0
        var filled = 0
        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                return []
            }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            var samples = [Float](repeating: 0, count: count)
            let status = samples.withUnsafeMutableBytes { buffer -> OSStatus in
                guard let base = buffer.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: base)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            for value in samples {
                current = max(current, abs(value))
                filled += 1
                if filled == bucketSize {
                    peaks.append(min(current, 1))
                    current = 0
                    filled = 0
                }
            }
        }
        if filled > 0 {
            peaks.append(min(current, 1))
        }
        return peaks
    }
}
