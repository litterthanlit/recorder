import AVFoundation
import Foundation

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
        audio: AudioMixSettings = AudioMixSettings()
    ) async throws -> Result {
        let composition = AVMutableComposition()

        if includeVideo, let videoTrack = try await asset.loadTracks(withMediaType: .video).first,
           let compositionTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try await insert(timeline: timeline, from: videoTrack, into: compositionTrack)
            compositionTrack.preferredTransform = try await videoTrack.load(.preferredTransform)
        }

        var audioTracks: [AVMutableCompositionTrack] = []
        var parameters: [AVMutableAudioMixInputParameters] = []
        if let audioRoles {
            let sourceTracks = try await asset.loadTracks(withMediaType: .audio)
            for (index, sourceTrack) in sourceTracks.enumerated() {
                guard let compositionTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else { continue }
                try await insert(timeline: timeline, from: sourceTrack, into: compositionTrack)
                audioTracks.append(compositionTrack)

                let role = index < audioRoles.count ? audioRoles[index] : .systemAudio
                let input = AVMutableAudioMixInputParameters(track: compositionTrack)
                input.setVolume(Float(audio.volume(for: role)), at: .zero)
                input.audioTimePitchAlgorithm = .spectral
                parameters.append(input)
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

    /// Lays `track` out along the edit.
    private static func insert(
        timeline: EditTimeline,
        from track: AVAssetTrack,
        into compositionTrack: AVMutableCompositionTrack
    ) async throws {
        let trackRange = try await track.load(.timeRange)
        let trackStart = CMTimeGetSeconds(trackRange.start)
        let trackEnd = CMTimeGetSeconds(trackRange.end)
        guard trackStart.isFinite, trackEnd.isFinite, trackEnd > trackStart else { return }

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
            if abs(entry.speed - 1) > 1e-9 {
                compositionTrack.scaleTimeRange(
                    CMTimeRange(start: insertAt, duration: sourceRange.duration),
                    toDuration: CMTime(seconds: kept.duration / entry.speed, preferredTimescale: timescale)
                )
            }
        }
    }
}
