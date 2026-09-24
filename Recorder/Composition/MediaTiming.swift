import CoreMedia
import Foundation

extension CMSampleBuffer {
    /// A copy with every timestamp moved by `offset`.
    ///
    /// Audio buffers carry many samples, usually described by one timing entry whose
    /// `duration` is the length of a *single* sample. Rebuilding timing from
    /// `CMSampleBufferGetDuration` (the whole buffer) and one entry would claim every
    /// sample lasts as long as the buffer, so shift the existing entries instead.
    func retimed(by offset: CMTime) -> CMSampleBuffer? {
        var entryCount: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            self,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &entryCount
        ) == OSStatus(noErr), entryCount > 0 else {
            return nil
        }

        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: entryCount)
        guard CMSampleBufferGetSampleTimingInfoArray(
            self,
            entryCount: entryCount,
            arrayToFill: &timing,
            entriesNeededOut: &entryCount
        ) == OSStatus(noErr) else {
            return nil
        }

        for index in timing.indices {
            timing[index].presentationTimeStamp = CMTimeAdd(timing[index].presentationTimeStamp, offset)
            if timing[index].decodeTimeStamp.isValid {
                timing[index].decodeTimeStamp = CMTimeAdd(timing[index].decodeTimeStamp, offset)
            }
        }

        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: self,
            sampleTimingEntryCount: entryCount,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy
        ) == OSStatus(noErr) else {
            return nil
        }
        return copy
    }
}

enum MediaTiming {
    /// Where a microphone buffer belongs on the recording's timeline, given its capture
    /// time on the host clock and the host time of the first video frame (t = 0).
    /// Both ScreenCaptureKit and the converted capture-session timestamps use the host
    /// clock, so audio lines up with video instead of starting at its own first sample.
    static func recordingTime(hostTime: CMTime, firstVideoFrameHostTime: CMTime) -> CMTime {
        CMTimeSubtract(hostTime, firstVideoFrameHostTime)
    }
}
