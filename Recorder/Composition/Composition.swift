import Foundation

/// Output clock for export.
///
/// ScreenCaptureKit only delivers a frame when the screen changes, so the source is
/// variable frame rate with long gaps during still moments. Exporting one output frame
/// per source frame would sample zoom, cursor, and ripple animation only at those
/// irregular moments (zooms snap, the cursor teleports, still endings disappear).
/// Instead the export runs on this fixed clock and each output frame shows the most
/// recent source frame at or before its time, which is what a player would display.
///
/// Output frames are on the edited timeline; `EditTimeline` says which source time each
/// one shows.
struct ConstantFrameRateTimeline: Equatable {
    let frameRate: Int
    /// Output duration in seconds (the edited length).
    let duration: TimeInterval

    /// Timestamps within this distance count as equal, absorbing rounding in PTS math.
    static let tolerance: TimeInterval = 0.0005

    init(frameRate: Int, duration: TimeInterval) {
        self.frameRate = max(1, frameRate)
        self.duration = max(0, duration)
    }

    /// Frames at 0, 1/fps, 2/fps, … strictly before `duration`, and at least one frame
    /// for any non-empty range.
    var frameCount: Int {
        guard duration > 0 else { return 0 }
        let exact = duration * Double(frameRate)
        return max(1, Int((exact - Self.tolerance * Double(frameRate)).rounded(.up)))
    }

    func outputTime(forFrame index: Int) -> TimeInterval {
        Double(index) / Double(frameRate)
    }


    /// Whether a source frame presented at `nextSourceTime` should replace the held frame
    /// when rendering the output frame for `sourceTime`.
    static func shouldAdvance(to nextSourceTime: TimeInterval, forSourceTime sourceTime: TimeInterval) -> Bool {
        nextSourceTime <= sourceTime + tolerance
    }

    /// For each output frame, the index of the source frame to show (sorted source
    /// times), following `edit` from output to source time. Before the first source frame,
    /// the first frame is shown. This is the exporter's frame-holding logic.
    func heldSourceFrameIndices(sourceTimes: [TimeInterval], edit: EditTimeline) -> [Int] {
        guard !sourceTimes.isEmpty else { return [] }
        var held = 0
        return (0..<frameCount).map { frame in
            let time = edit.sourceTime(forOutput: outputTime(forFrame: frame))
            while held + 1 < sourceTimes.count,
                  Self.shouldAdvance(to: sourceTimes[held + 1], forSourceTime: time) {
                held += 1
            }
            return held
        }
    }
}
