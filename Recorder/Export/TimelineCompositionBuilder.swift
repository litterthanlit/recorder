import AVFoundation
import Foundation
import MediaToolbox

/// Builds an `AVMutableComposition` that plays a recording as edited: kept segments in
/// order, each scaled to its speed. The editor's player plays it (so preview audio and
/// video follow cuts and speed changes), and export reads its audio from it.
///
/// Every track is laid out from `EditTimeline.compositionPlan`, the same numbers the
/// renderer uses to map output time back to source time, so picture, audio and overlays
/// stay in step. A track that doesn't cover a segment (the camera starts a moment after
/// the screen) just has an empty stretch there.
enum TimelineCompositionBuilder {
    struct Result {
        let composition: AVMutableComposition
        /// Per-track levels for the audio tracks; `nil` when there's no audio.
        let audioMix: AVMutableAudioMix?
        let audioTracks: [AVMutableCompositionTrack]
    }

    private static let timescale: CMTimeScale = 60_000

    /// - Parameters:
    ///   - includeVideo: add the first video track.
    ///   - audioRoles: when non-nil, add the audio tracks, levelled by `audio` according
    ///     to these roles (in track order).
    static func build(
        asset: AVAsset,
        timeline: EditTimeline,
        includeVideo: Bool,
        audioRoles: [AudioTrackRole]?,
        audio: AudioMixSettings = AudioMixSettings(),
        musicURL: URL? = nil,
        music: BackgroundMusicSettings = BackgroundMusicSettings()
    ) async throws -> Result {
        let composition = AVMutableComposition()

        if includeVideo, let videoTrack = try await asset.loadTracks(withMediaType: .video).first,
           let compositionTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let inserted = try await insert(timeline: timeline, from: videoTrack, into: compositionTrack)
            if inserted {
                compositionTrack.preferredTransform = try await videoTrack.load(.preferredTransform)
            } else {
                composition.removeTrack(compositionTrack)
            }
        }

        var audioTracks: [AVMutableCompositionTrack] = []
        var parameters: [AVMutableAudioMixInputParameters] = []
        var hasAudibleMicrophone = false
        if let audioRoles {
            let sourceTracks = try await asset.loadTracks(withMediaType: .audio)
            // Fades at cuts and quiet over sped-up parts, when they're on.
            let envelope = AudioEnvelope.ramps(for: timeline, audio: audio)
            for (index, sourceTrack) in sourceTracks.enumerated() {
                guard let compositionTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else { continue }
                let inserted = try await insert(timeline: timeline, from: sourceTrack, into: compositionTrack)
                // An empty audio track can fail AVAssetReaderAudioMixOutput.startReading().
                guard inserted else {
                    composition.removeTrack(compositionTrack)
                    continue
                }
                audioTracks.append(compositionTrack)

                let role = index < audioRoles.count ? audioRoles[index] : .systemAudio
                let input = AVMutableAudioMixInputParameters(track: compositionTrack)
                let requestedLevel = Float(audio.volume(for: role))
                if role == .microphone, requestedLevel > 0.01 {
                    hasAudibleMicrophone = true
                }
                // AVAudioMix enforces 0...1; apply >1.0 boost via a pre-effects processing tap
                // with soft limiting so cut fades and muting still fade cleanly to 0.
                let mixLevel = min(max(requestedLevel, 0), 1)
                if requestedLevel > 1.001, let tap = AudioGainTap.make(gain: requestedLevel) {
                    input.audioTapProcessor = tap
                }
                if envelope.isEmpty {
                    input.setVolume(mixLevel, at: .zero)
                } else {
                    apply(envelope, level: mixLevel, to: input)
                }
                input.audioTimePitchAlgorithm = .spectral
                parameters.append(input)
            }

            if let musicURL, music.clampedVolume > 0.001, timeline.outputDuration > 0.05 {
                if let musicParam = try await insertMusic(
                    from: musicURL,
                    into: composition,
                    outputDuration: timeline.outputDuration,
                    settings: music,
                    ducked: hasAudibleMicrophone && music.duckUnderNarration
                ) {
                    audioTracks.append(musicParam.track)
                    parameters.append(musicParam.input)
                }
            }
        }

        let audioMix: AVMutableAudioMix?
        if parameters.isEmpty {
            audioMix = nil
        } else {
            let mix = AVMutableAudioMix()
            mix.inputParameters = parameters
            audioMix = mix
        }
        return Result(composition: composition, audioMix: audioMix, audioTracks: audioTracks)
    }

    /// Inserts a looping background music track covering `outputDuration` with smooth fade-in and fade-out.
    private static func insertMusic(
        from url: URL,
        into composition: AVMutableComposition,
        outputDuration: TimeInterval,
        settings: BackgroundMusicSettings,
        ducked: Bool
    ) async throws -> (track: AVMutableCompositionTrack, input: AVMutableAudioMixInputParameters)? {
        let musicAsset = AVURLAsset(url: url)
        guard let sourceTrack = try await musicAsset.loadTracks(withMediaType: .audio).first else { return nil }
        let trackRange = try await sourceTrack.load(.timeRange)
        let sourceDuration = CMTimeGetSeconds(trackRange.duration)
        guard sourceDuration.isFinite, sourceDuration > 0.05,
              let compositionTrack = composition.addMutableTrack(
                  withMediaType: .audio,
                  preferredTrackID: kCMPersistentTrackID_Invalid
              )
        else { return nil }

        var cursor: TimeInterval = 0
        while cursor < outputDuration - 0.005 {
            let chunk = min(sourceDuration, outputDuration - cursor)
            let range = CMTimeRange(
                start: trackRange.start,
                duration: CMTime(seconds: chunk, preferredTimescale: timescale)
            )
            let at = CMTime(seconds: cursor, preferredTimescale: timescale)
            try compositionTrack.insertTimeRange(range, of: sourceTrack, at: at)
            cursor += chunk
        }

        let baseLevel = Float(settings.clampedVolume * (ducked ? 0.55 : 1.0))
        let input = AVMutableAudioMixInputParameters(track: compositionTrack)
        let fade = min(max(settings.fadeDuration, 0), outputDuration * 0.4)
        if fade > 0.02 {
            let fadeInEnd = CMTime(seconds: fade, preferredTimescale: timescale)
            let fadeOutStart = CMTime(seconds: max(fade, outputDuration - fade), preferredTimescale: timescale)
            let totalEnd = CMTime(seconds: outputDuration, preferredTimescale: timescale)
            input.setVolumeRamp(fromStartVolume: 0, toEndVolume: baseLevel, timeRange: CMTimeRange(start: .zero, end: fadeInEnd))
            if totalEnd > fadeOutStart {
                input.setVolumeRamp(fromStartVolume: baseLevel, toEndVolume: 0, timeRange: CMTimeRange(start: fadeOutStart, end: totalEnd))
            }
        } else {
            input.setVolume(baseLevel, at: .zero)
        }
        return (compositionTrack, input)
    }

    /// The track's level, shaped by `envelope` (output time).
    private static func apply(_ envelope: [VolumeRamp], level: Float, to input: AVMutableAudioMixInputParameters) {
        let clampedLevel = min(max(level, 0), 1)
        if let first = envelope.first, first.start > 1e-9 {
            input.setVolume(clampedLevel, at: .zero)
        }
        var previousEnd = CMTime.zero
        for ramp in envelope {
            // Convert start and end boundaries to CMTime directly (not independent duration)
            // and clamp to `previousEnd` so rounding can never produce intersecting or
            // zero-duration ranges (which throw NSInvalidArgumentException in AVAudioMix).
            let rawStart = CMTime(seconds: ramp.start, preferredTimescale: timescale)
            let start = CMTimeMaximum(rawStart, previousEnd)
            let end = CMTime(seconds: ramp.start + ramp.duration, preferredTimescale: timescale)
            guard end > start else { continue }
            let fromVolume = clampedLevel * Float(min(max(ramp.from, 0), 1))
            let toVolume = clampedLevel * Float(min(max(ramp.to, 0), 1))
            input.setVolumeRamp(
                fromStartVolume: fromVolume,
                toEndVolume: toVolume,
                timeRange: CMTimeRange(start: start, end: end)
            )
            previousEnd = end
        }
    }

    /// Lays `track` out along the edit. Returns `true` if at least one segment was inserted.
    @discardableResult
    private static func insert(
        timeline: EditTimeline,
        from track: AVAssetTrack,
        into compositionTrack: AVMutableCompositionTrack
    ) async throws -> Bool {
        let trackRange = try await track.load(.timeRange)
        let trackStart = CMTimeGetSeconds(trackRange.start)
        let trackEnd = CMTimeGetSeconds(trackRange.end)
        guard trackStart.isFinite, trackEnd.isFinite, trackEnd > trackStart else { return false }

        var insertedAny = false
        for entry in timeline.compositionPlan {
            let kept = TimeSpan(start: max(entry.source.start, trackStart), end: min(entry.source.end, trackEnd))
            guard kept.duration > 0.0005 else { continue }

            let outputStart = entry.outputStart + (kept.start - entry.source.start) / entry.speed
            // Never insert before what's already there (rounding can put the next segment a
            // hair before the previous one's end), or the tail would move after it.
            let currentEnd = compositionTrack.timeRange.end
            var insertAt = CMTime(seconds: outputStart, preferredTimescale: timescale)
            if insertAt < currentEnd {
                insertAt = currentEnd
            } else if insertAt > currentEnd {
                compositionTrack.insertEmptyTimeRange(CMTimeRange(start: currentEnd, end: insertAt))
            }

            let sourceRange = CMTimeRange(
                start: CMTime(seconds: kept.start, preferredTimescale: timescale),
                duration: CMTime(seconds: kept.duration, preferredTimescale: timescale)
            )
            try compositionTrack.insertTimeRange(sourceRange, of: track, at: insertAt)
            let insertedDuration = CMTimeSubtract(compositionTrack.timeRange.end, insertAt)
            guard insertedDuration > .zero else { continue }
            insertedAny = true
            if abs(entry.speed - 1) > 1e-9 {
                let targetDuration = CMTime(
                    seconds: CMTimeGetSeconds(insertedDuration) / entry.speed,
                    preferredTimescale: timescale
                )
                if targetDuration > .zero {
                    compositionTrack.scaleTimeRange(
                        CMTimeRange(start: insertAt, duration: insertedDuration),
                        toDuration: targetDuration
                    )
                }
            }
        }
        return insertedAny
    }
}

/// Applies >1.0 audio boost with a gentle soft-clip limiter inside an `AVAudioMix`.
private enum AudioGainTap {
    private final class Context {
        let gain: Float
        var isFloat32 = false

        init(gain: Float) {
            self.gain = gain
        }
    }

    static func make(gain: Float) -> MTAudioProcessingTap? {
        let context = Context(gain: gain)
        let retained = Unmanaged.passRetained(context)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: retained.toOpaque(),
            init: { _, clientInfo, tapStorageOut in
                tapStorageOut.pointee = clientInfo
            },
            finalize: { tap in
                let storage = MTAudioProcessingTapGetStorage(tap)
                Unmanaged<Context>.fromOpaque(storage).release()
            },
            prepare: { tap, _, processingFormat in
                let context = Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let asbd = processingFormat.pointee
                context.isFloat32 = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0 && asbd.mBitsPerChannel == 32
            },
            unprepare: nil,
            process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap,
                    numberFrames,
                    bufferListInOut,
                    flagsOut,
                    nil,
                    numberFramesOut
                )
                guard status == noErr else { return }
                let context = Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                guard context.isFloat32 else { return }
                let gain = context.gain
                let buffers = UnsafeMutableAudioBufferListPointer(bufferListInOut)
                for buffer in buffers {
                    guard let data = buffer.mData else { continue }
                    let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    let samples = data.bindMemory(to: Float.self, capacity: count)
                    for index in 0..<count {
                        let boosted = samples[index] * gain
                        let magnitude = abs(boosted)
                        if magnitude > 0.85 {
                            let limited = 0.85 + 0.15 * tanh((magnitude - 0.85) / 0.15)
                            samples[index] = boosted >= 0 ? limited : -limited
                        } else {
                            samples[index] = boosted
                        }
                    }
                }
            }
        )
        var tap: Unmanaged<MTAudioProcessingTap>?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PreEffects,
            &tap
        )
        guard status == noErr, let tap else {
            retained.release()
            return nil
        }
        return tap.takeRetainedValue()
    }
}
