import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

/// Reads what take analysis needs from a recording's files: when frames exist, how much
/// the screen changed, and speech on the microphone. Scans run in the background and are
/// kept for each take until its recording file changes, so an agent that stopped waiting
/// gets the result on its next call.
@MainActor
final class AgentMediaScanner {
    enum State {
        case running(progress: Double)
        case done(TakeMediaScan)
        case failed(String)
    }

    struct Key: Hashable {
        let take: UUID
        let modified: Date?
    }

    /// What a scan needs to know about the take.
    struct Request {
        let videoURL: URL
        let metadata: ProjectMetadata
    }

    private final class Job {
        let progress = ScanProgress()
        var scan: Task<TakeMediaScan, Error>?
        var result: Result<TakeMediaScan, Error>?
    }

    private var jobs: [Key: Job] = [:]
    private var order: [Key] = []
    private static let remembered = 12

    /// Starts reading `project` unless it's read already or being read (a failed scan is
    /// tried again).
    func start(_ project: RecorderProject) -> Key {
        let videoURL = project.videoURL
        let attributes = try? FileManager.default.attributesOfItem(atPath: videoURL.path)
        let key = Key(take: project.metadata.id, modified: attributes?[.modificationDate] as? Date)
        if let job = jobs[key] {
            switch job.result {
            case .failure?:
                break
            case .success?, nil:
                return key
            }
        }

        let request = Request(videoURL: videoURL, metadata: project.metadata)
        let job = Job()
        let progress = job.progress
        let scan = Task.detached(priority: .utility) {
            try await AgentMediaScanner.scan(request, progress: progress)
        }
        job.scan = scan
        Task {
            do {
                job.result = .success(try await scan.value)
            } catch {
                Log.agent.error("Reading a take for analysis failed: \(error.localizedDescription, privacy: .public)")
                job.result = .failure(error)
            }
        }
        jobs[key] = job
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > Self.remembered {
            let oldest = order.removeFirst()
            jobs[oldest]?.scan?.cancel()
            jobs[oldest] = nil
        }
        return key
    }

    func state(_ key: Key) -> State? {
        guard let job = jobs[key] else { return nil }
        switch job.result {
        case let .success(scan)?:
            return .done(scan)
        case let .failure(error)?:
            return .failed(error.localizedDescription)
        case nil:
            return .running(progress: job.progress.value)
        }
    }

    /// Waits up to `timeout` seconds for the scan, reporting its progress. Throws
    /// `CancellationError` if the agent stops waiting (the scan goes on).
    func wait(_ key: Key, timeout: TimeInterval, progress: MCPProgress) async throws -> State {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            guard let current = self.state(key) else {
                return .failed("Trace forgot this scan; try again.")
            }
            guard case let .running(fraction) = current, ProcessInfo.processInfo.systemUptime < deadline else {
                return current
            }
            progress.report(min(fraction, 0.99), "Reading the recording: \(Int((fraction * 100).rounded()))%")
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    // MARK: - Reading the files

    nonisolated static func scan(_ request: Request, progress: ScanProgress) async throws -> TakeMediaScan {
        let asset = AVURLAsset(url: request.videoURL)
        let frames = try await frameTimes(asset)
        progress.set(0.05)
        try Task.checkCancellation()

        let seconds = frames.map { $0.seconds }
        let indices = VisualChange.sampleIndices(frameTimes: seconds, duration: request.metadata.duration)
        let screen = try await screenChanges(
            asset,
            times: indices.map { frames[$0] },
            size: CGSize(width: request.metadata.width, height: request.metadata.height),
            progress: progress,
            from: 0.05,
            to: 0.9
        )
        try Task.checkCancellation()

        let speech = try await self.speech(asset, metadata: request.metadata)
        progress.set(1)
        return TakeMediaScan(frameTimes: seconds, screen: screen, speech: speech)
    }

    /// Presentation times of every video frame, read without decoding anything.
    nonisolated static func frameTimes(_ asset: AVURLAsset) async throws -> [CMTime] {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? CocoaError(.fileReadUnknown)
        }
        var times: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            let count = CMSampleBufferGetNumSamples(sample)
            if count == 1 {
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                if time.isNumeric {
                    times.append(time)
                }
            } else if count > 1 {
                times += timingInfo(sample).map { $0.presentationTimeStamp }.filter { $0.isNumeric }
            }
        }
        if reader.status == .failed {
            throw reader.error ?? CocoaError(.fileReadUnknown)
        }
        return times.sorted { CMTimeCompare($0, $1) < 0 }
    }

    nonisolated private static func timingInfo(_ sample: CMSampleBuffer) -> [CMSampleTimingInfo] {
        var needed: CMItemCount = 0
        let counted = CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &needed)
        guard counted == OSStatus(noErr), needed > 0 else { return [] }
        var infos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: needed)
        let status = CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: needed, arrayToFill: &infos, entriesNeededOut: &needed)
        return status == OSStatus(noErr) ? infos : []
    }

    /// How much of the screen changed at each of `times` (exact frame times), from small
    /// greyscale thumbnails; `nil` when none could be made.
    nonisolated static func screenChanges(
        _ asset: AVURLAsset,
        times: [CMTime],
        size: CGSize,
        progress: ScanProgress,
        from start: Double,
        to end: Double
    ) async throws -> [VisualChangeSample]? {
        guard !times.isEmpty else { return [] }
        let width = VisualChange.thumbnailWidth
        let height = max(1, Int((Double(width) * Double(size.height) / Double(max(size.width, 1))).rounded()))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: width, height: height)

        var samples: [VisualChangeSample] = []
        var previous: [UInt8]?
        var made = 0
        for (index, time) in times.enumerated() {
            try Task.checkCancellation()
            if let image = try? await generator.image(at: time).image,
               let pixels = greyscale(image, width: width, height: height) {
                made += 1
                if let previous {
                    samples.append(VisualChangeSample(time: time.seconds, area: VisualChange.changedArea(previous, pixels)))
                }
                previous = pixels
            }
            progress.set(start + (end - start) * Double(index + 1) / Double(times.count))
        }
        return made > 0 ? samples : nil
    }

    /// `image` drawn into a `width`×`height` greyscale bitmap.
    nonisolated static func greyscale(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    /// Speech on the microphone tracks; `nil` when there are none.
    nonisolated static func speech(_ asset: AVURLAsset, metadata: ProjectMetadata) async throws -> [TimeSpan]? {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let roles = metadata.resolvedAudioTrackRoles(trackCount: tracks.count)
        let microphones = zip(tracks, roles).filter { $0.1 == .microphone }.map { $0.0 }
        guard !microphones.isEmpty else { return nil }

        let reader = try AVAssetReader(asset: asset)
        let sampleRate = 8_000.0
        let output = AVAssetReaderAudioMixOutput(audioTracks: microphones, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? CocoaError(.fileReadUnknown)
        }

        let detector = SpeechDetector()
        var meter = LoudnessMeter(frameLength: Int(sampleRate / detector.frameRate))
        var start: TimeInterval?
        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            let time = CMSampleBufferGetPresentationTimeStamp(buffer)
            if time.isNumeric {
                if let start {
                    // Keep later levels in place across a gap (dropped audio).
                    meter.pad(toSample: Int(((time.seconds - start) * sampleRate).rounded()))
                } else {
                    start = time.seconds
                }
            }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            var samples = [Float](repeating: 0, count: count)
            let status = samples.withUnsafeMutableBytes { bytes -> OSStatus in
                guard let base = bytes.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: base)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            meter.add(samples)
        }
        if reader.status == .failed {
            throw reader.error ?? CocoaError(.fileReadUnknown)
        }
        return detector.speech(levels: meter.finish(), start: start ?? 0)
    }
}

/// A scan's progress (0…1, only ever rising), written in the background and read on the
/// main actor.
final class ScanProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Double = 0

    var value: Double {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func set(_ value: Double) {
        lock.lock()
        current = max(current, min(max(value, 0), 1))
        lock.unlock()
    }
}
