import Foundation
import Testing
@testable import RecorderCore

@Suite("EditTimeline")
struct EditTimelineTests {
    private func timeline(_ spans: [(Double, Double, Double)], duration: Double = 100) -> EditTimeline {
        EditTimeline(
            segments: spans.map { EditSegment(source: TimeSpan(start: $0.0, end: $0.1), speed: $0.2) },
            sourceDuration: duration
        )
    }

    // MARK: Mapping

    @Test func wholeRecordingIsTheIdentity() {
        let edit = EditTimeline(sourceDuration: 10)
        #expect(isClose(edit.outputDuration, 10))
        for time in stride(from: 0.0, through: 10, by: 0.37) {
            #expect(isClose(edit.sourceTime(forOutput: time), time))
            #expect(isClose(edit.outputTime(forSource: time) ?? -1, time))
        }
        #expect(!edit.hasCuts && !edit.hasSpeedChanges)
    }

    @Test func cutsSkipSourceTime() {
        // Keep 0–4 and 6–10: output is 8 s long.
        let edit = timeline([(0, 4, 1), (6, 10, 1)], duration: 10)
        #expect(isClose(edit.outputDuration, 8))
        #expect(isClose(edit.sourceTime(forOutput: 3), 3))
        #expect(isClose(edit.sourceTime(forOutput: 5), 7))
        #expect(edit.hasCuts)
    }

    @Test func aCutBoundaryShowsTheLaterSegment() {
        let edit = timeline([(0, 4, 1), (6, 10, 1)], duration: 10)
        #expect(isClose(edit.sourceTime(forOutput: 4), 6))
        #expect(isClose(edit.sourceTime(forOutput: 3.999_999), 3.999_999))
    }

    @Test func outputTimeIsClampedToTheEdit() {
        let edit = timeline([(2, 4, 1)], duration: 10)
        #expect(isClose(edit.sourceTime(forOutput: -5), 2))
        #expect(isClose(edit.sourceTime(forOutput: 50), 4))
    }

    @Test func speedStretchesOutputTime() {
        let edit = timeline([(0, 4, 2), (4, 6, 0.5)], duration: 10)
        #expect(isClose(edit.outputDuration, 2 + 4))
        #expect(isClose(edit.sourceTime(forOutput: 1), 2))
        #expect(isClose(edit.sourceTime(forOutput: 3), 4.5))
        #expect(isClose(edit.outputTime(forSource: 5) ?? -1, 4))
        #expect(edit.hasSpeedChanges)
    }

    @Test func cutTimesHaveNoOutputTime() {
        let edit = timeline([(0, 4, 1), (6, 10, 1)], duration: 10)
        #expect(edit.outputTime(forSource: 5) == nil)
        #expect(edit.outputTime(forSource: 11) == nil)
        #expect(isClose(edit.outputTime(forSource: 10) ?? -1, 8))
        #expect(isClose(edit.outputTimeClamped(forSource: 5), 4))
        #expect(isClose(edit.outputTimeClamped(forSource: 11), 8))
    }

    @Test func sourceSpansLoseTheirCutParts() {
        let edit = timeline([(0, 4, 1), (6, 10, 1)], duration: 10)
        // 3–7 keeps 3–4 and 6–7, which run on in the output: 3–5.
        let across = edit.outputSpans(forSource: TimeSpan(start: 3, end: 7))
        #expect(across.count == 1)
        #expect(isClose(across[0].start, 3) && isClose(across[0].end, 5))
        // Starting inside the cut: only the kept tail.
        let tail = edit.outputSpans(forSource: TimeSpan(start: 5, end: 7))
        #expect(tail.count == 1)
        #expect(isClose(tail[0].start, 4) && isClose(tail[0].end, 5))
        #expect(edit.outputSpans(forSource: TimeSpan(start: 4.5, end: 5.5)).isEmpty)
        // Kept pieces on both sides of two cuts join up too.
        let edit3 = timeline([(0, 2, 1), (4, 6, 1), (8, 10, 1)], duration: 10)
        let pieces = edit3.outputSpans(forSource: TimeSpan(start: 1, end: 9))
        #expect(pieces.count == 1)
        #expect(isClose(pieces[0].start, 1) && isClose(pieces[0].end, 5))
    }

    @Test func spansAcrossASplitStayOnePiece() {
        var edit = EditTimeline(sourceDuration: 10)
        #expect(edit.split(atOutput: 5))
        let spans = edit.outputSpans(forSource: TimeSpan(start: 3, end: 7))
        #expect(spans.count == 1)
        #expect(isClose(spans[0].start, 3) && isClose(spans[0].end, 7))
    }

    @Test func mappingNeverGoesBackwards() {
        let edit = timeline([(0.5, 2, 1.5), (3, 3.7, 0.25), (5, 9, 4), (9.5, 10, 1)], duration: 10)
        var previous = -Double.infinity
        for step in 0...4000 {
            let output = edit.outputDuration * Double(step) / 4000
            let source = edit.sourceTime(forOutput: output)
            #expect(source >= previous - 1e-12)
            previous = source
        }
    }

    @Test func outputSourceOutputRoundTrips() {
        let edit = timeline([(0.5, 2, 1.5), (3, 3.7, 0.25), (5, 9, 4)], duration: 10)
        for step in 0..<200 {
            let output = edit.outputDuration * Double(step) / 200
            let source = edit.sourceTime(forOutput: output)
            #expect(isClose(edit.outputTime(forSource: source) ?? -1, output, tolerance: 1e-9))
        }
    }

    @Test func compositionPlanTilesTheOutput() {
        let edit = timeline([(0, 2, 2), (3, 5, 1), (7, 8, 0.5)], duration: 10)
        let plan = edit.compositionPlan
        #expect(plan.count == 3)
        var expectedStart = 0.0
        for entry in plan {
            #expect(isClose(entry.outputStart, expectedStart))
            #expect(isClose(entry.outputDuration, entry.source.duration / entry.speed))
            expectedStart += entry.outputDuration
        }
        #expect(isClose(expectedStart, edit.outputDuration))
    }

    // MARK: Editing

    @Test func splitMakesTwoSegmentsAtThePlayhead() {
        var edit = EditTimeline(sourceDuration: 10)
        #expect(edit.split(atOutput: 4))
        #expect(edit.segments.count == 2)
        #expect(isClose(edit.segments[0].source.end, 4))
        #expect(isClose(edit.segments[1].source.start, 4))
        #expect(isClose(edit.outputDuration, 10))
    }

    @Test func splitAtAnEdgeIsRefused() {
        var edit = EditTimeline(sourceDuration: 10)
        #expect(!edit.split(atOutput: 0))
        #expect(!edit.split(atOutput: 10))
        #expect(!edit.split(atOutput: 0.01))
        #expect(edit.segments.count == 1)
    }

    @Test func deleteRipplesAndKeepsTheLastSegment() {
        var edit = EditTimeline(sourceDuration: 10)
        edit.split(atOutput: 3)
        edit.split(atOutput: 6)
        let middle = edit.segments[1].id
        #expect(edit.deleteSegment(id: middle))
        #expect(isClose(edit.outputDuration, 7))
        #expect(isClose(edit.sourceTime(forOutput: 3), 6))

        #expect(edit.deleteSegment(id: edit.segments[0].id))
        #expect(!edit.deleteSegment(id: edit.segments[0].id))
        #expect(edit.segments.count == 1)
    }

    @Test func speedIsClamped() {
        var edit = EditTimeline(sourceDuration: 10)
        let id = edit.segments[0].id
        edit.setSpeed(100, forSegment: id)
        #expect(edit.segments[0].speed == EditTimeline.speedRange.upperBound)
        edit.setSpeed(0, forSegment: id)
        #expect(edit.segments[0].speed == EditTimeline.speedRange.lowerBound)
        edit.setSpeed(.nan, forSegment: id)
        #expect(edit.segments[0].speed == 1)
    }

    @Test func edgesCanReclaimCutMaterialButNotOverlap() {
        var edit = timeline([(0, 4, 1), (6, 10, 1)], duration: 12)
        let second = edit.segments[1].id
        edit.setSourceStart(5, forSegment: second)
        #expect(isClose(edit.segments[1].source.start, 5))
        edit.setSourceStart(2, forSegment: second)
        #expect(isClose(edit.segments[1].source.start, 4))
        edit.setSourceEnd(20, forSegment: second, sourceDuration: 12)
        #expect(isClose(edit.segments[1].source.end, 12))
        edit.setSourceEnd(0, forSegment: second, sourceDuration: 12)
        #expect(isClose(edit.segments[1].source.duration, EditTimeline.minimumSegmentDuration))
    }

    @Test func trimMovesTheOuterEdges() {
        var edit = EditTimeline(sourceDuration: 10)
        edit.split(atOutput: 5)
        edit.setTrimStart(1)
        edit.setTrimEnd(8, sourceDuration: 10)
        #expect(isClose(edit.trimStart, 1))
        #expect(isClose(edit.trimEnd, 8))
        #expect(isClose(edit.outputDuration, 7))
    }

    @Test func excludingARangeCutsAcrossSegments() {
        var edit = EditTimeline(sourceDuration: 10)
        edit.split(atOutput: 5)
        #expect(edit.excludeSource(TimeSpan(start: 3, end: 7)))
        #expect(edit.segments.count == 2)
        #expect(isClose(edit.outputDuration, 6))
        #expect(edit.outputTime(forSource: 4) == nil)

        var whole = EditTimeline(sourceDuration: 10)
        #expect(!whole.excludeSource(TimeSpan(start: -1, end: 11)))
        #expect(isClose(whole.outputDuration, 10))
    }

    @Test func speedingUpARangeSplitsAtItsEdges() {
        var edit = EditTimeline(sourceDuration: 10)
        edit.applySpeed(4, toSource: TimeSpan(start: 2, end: 6))
        #expect(edit.segments.map(\.speed) == [1, 4, 1])
        #expect(isClose(edit.outputDuration, 2 + 1 + 4))
        #expect(Set(edit.segments.map(\.id)).count == 3)
    }

    @Test func speedingUpATinySliverChangesNothing() {
        var edit = EditTimeline(sourceDuration: 10)
        edit.applySpeed(4, toSource: TimeSpan(start: 5, end: 5.01))
        #expect(edit.segments.count == 1)
        #expect(isClose(edit.outputDuration, 10))
    }

    // MARK: Migration and cleanup

    @Test func legacyTrimBecomesOneSegment() {
        let edit = EditTimeline.legacy(trimStart: 1.5, trimEnd: 8, sourceDuration: 10)
        #expect(edit.segments.count == 1)
        #expect(isClose(edit.trimStart, 1.5) && isClose(edit.trimEnd, 8))
        let open = EditTimeline.legacy(trimStart: 0, trimEnd: nil, sourceDuration: 10)
        #expect(isClose(open.trimEnd, 10))
        let beyond = EditTimeline.legacy(trimStart: 0, trimEnd: 50, sourceDuration: 10)
        #expect(isClose(beyond.trimEnd, 10))
    }

    @Test func normalizationRepairsBadSegments() {
        let edit = timeline([(5, 8, 1), (-2, 3, 0), (7, 12, 1), (9, 9.001, 1)], duration: 10)
        #expect(edit.segments.count == 3)
        #expect(isClose(edit.segments[0].source.start, 0))
        #expect(edit.segments[0].speed == EditTimeline.speedRange.lowerBound)
        #expect(isClose(edit.segments[2].source.start, 8))
        #expect(isClose(edit.segments[2].source.end, 10))
        let empty = EditTimeline(segments: [], sourceDuration: 4)
        #expect(isClose(empty.outputDuration, 4))
    }

    @Test func codableRoundTripAndTolerantDecoding() throws {
        var edit = EditTimeline(sourceDuration: 10)
        edit.split(atOutput: 5)
        edit.setSpeed(2, forSegment: edit.segments[1].id)
        let decoded = try JSONDecoder().decode(EditTimeline.self, from: JSONEncoder().encode(edit))
        #expect(decoded == edit)

        let json = #"{ "segments": [ { "source": { "start": 1, "end": 2 } } ] }"#
        let minimal = try JSONDecoder().decode(EditTimeline.self, from: Data(json.utf8))
        #expect(minimal.segments.first?.speed == 1)
    }
}

@Suite("IdleStretchDetector")
struct IdleStretchDetectorTests {
    @Test func noActivityMeansAllIdle() {
        let stretches = IdleStretchDetector.idleStretches(activity: [], within: TimeSpan(start: 0, end: 10))
        #expect(stretches == [TimeSpan(start: 0, end: 10)])
    }

    @Test func steadyActivityHasNoIdleStretches() {
        let activity = stride(from: 0.0, to: 10, by: 0.5).map { $0 }
        #expect(IdleStretchDetector.idleStretches(activity: activity, within: TimeSpan(start: 0, end: 10)).isEmpty)
    }

    @Test func padsAroundActivity() {
        let stretches = IdleStretchDetector.idleStretches(
            activity: [1, 6],
            within: TimeSpan(start: 0, end: 7),
            minimumIdle: 2,
            padding: 0.5
        )
        #expect(stretches.count == 1)
        #expect(isClose(stretches[0].start, 1.5))
        #expect(isClose(stretches[0].end, 5.5))
    }

    @Test func idleAtTheEdgesIsFound() {
        let stretches = IdleStretchDetector.idleStretches(
            activity: [4],
            within: TimeSpan(start: 0, end: 10),
            minimumIdle: 2,
            padding: 0.5
        )
        #expect(stretches == [TimeSpan(start: 0, end: 3.5), TimeSpan(start: 4.5, end: 10)])
    }
}
