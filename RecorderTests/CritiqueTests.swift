import CoreGraphics
import Foundation
import Testing
@testable import RecorderCore

private let source = CGSize(width: 1920, height: 1080)
private let canvas = CGSize(width: 1920, height: 1080)

/// A grid `rows` tall: each row's brightness from `brightness(row)`.
private func grid(rows: Int = 18, columns: Int = 32, _ brightness: (Int) -> Double) -> LumaGrid {
    LumaGrid(width: columns, height: rows, values: (0..<rows).flatMap { row in Array(repeating: brightness(row), count: columns) })
}

/// Dark above, bright below.
private let darkTopBrightBottom = grid { $0 < 9 ? 0.1 : 0.9 }
/// A detailed, middling picture.
private let busy = LumaGrid(width: 32, height: 18, values: (0..<(32 * 18)).map { $0 % 2 == 0 ? 0.3 : 0.5 })

private func snapshot(duration: TimeInterval = 20, texts: [TextOverlay] = [], zooms: [ZoomKeyframe] = []) -> EditorSnapshot {
    var settings = ProjectEditSettings()
    settings.setTimeline(EditTimeline(sourceDuration: duration))
    settings.textOverlays = texts
    return EditorSnapshot(keyframes: zooms, editSettings: settings)
}

private func moment(_ time: TimeInterval) -> CritiqueMoment {
    CritiqueMoment(output: time, source: time, reason: "test")
}

private func still(_ time: TimeInterval, backdrop: LumaGrid = busy, texts: [StillMeasurement.Text] = []) -> StillMeasurement {
    StillMeasurement(moment: moment(time), backdrop: backdrop, texts: texts)
}

private func judge(_ stills: [StillMeasurement], _ edit: EditorSnapshot, take: AgentEditTake = AgentEditTake(duration: 20, sourceSize: source), canvas: CGSize = canvas, analysis: TakeAnalysis? = nil) -> Critique {
    Critic.judge(stills, snapshot: edit, take: take, canvas: canvas, analysis: analysis)
}

@Suite("Critique")
struct CritiqueTests {
    @Test func gridsMeasureBrightnessAndChange() {
        let top = darkTopBrightBottom.stats(in: CGRect(x: 0, y: 0, width: 1, height: 0.5))
        #expect(isClose(top.mean, 0.1) && isClose(top.spread, 0, tolerance: 1e-6))
        let whole = darkTopBrightBottom.stats()
        #expect(isClose(whole.mean, 0.5) && isClose(whole.spread, 0.4, tolerance: 1e-6))
        #expect(isClose(darkTopBrightBottom.difference(from: darkTopBrightBottom), 0))
        #expect(isClose(darkTopBrightBottom.difference(from: grid { _ in 0.1 }), 0.4))
    }

    @Test func picksTheMomentsWorthJudging() {
        var edit = snapshot(
            texts: [TextOverlay(text: "Connect your repo", span: TimeSpan(start: 12, end: 15))],
            zooms: [ZoomKeyframe(startTime: 3, peakTime: 3.5, endTime: 6, center: CGPoint(x: 0.5, y: 0.5), scale: 2, source: .manual)]
        )
        var timeline = EditTimeline(sourceDuration: 20)
        timeline.excludeSource(TimeSpan(start: 8, end: 10))
        edit.editSettings.setTimeline(timeline)
        let moments = Critic.moments(edit, duration: 20)
        let reasons = moments.map(\.reason)
        #expect(reasons.contains("the opening") && reasons.contains("shot 2"))
        #expect(reasons.contains("text \"Connect your repo\"") && reasons.contains("a zoom arrives"))
        for (first, second) in zip(moments, moments.dropFirst()) {
            #expect(second.output - first.output >= 0.4 - 1e-9)
        }
        // Moments after the cut are on both clocks.
        let text = moments.first { $0.reason.hasPrefix("text") }
        #expect(text.map { isClose($0.source - $0.output, 2) } == true)
    }

    @Test func movesATitleOffABrightBackground() throws {
        let title = TextOverlay(text: "Acme 2.0", span: TimeSpan(start: 0, end: 5), center: CGPoint(x: 0.5, y: 0.82), style: .title)
        let critique = judge(
            [still(2, backdrop: darkTopBrightBottom, texts: [StillMeasurement.Text(id: title.id, frame: CGRect(x: 0.35, y: 0.77, width: 0.3, height: 0.1))])],
            snapshot(texts: [title])
        )
        let issue = try #require(critique.stills.first?.issues.first { $0.kind == .unreadable })
        guard case let .moveText(id, to)? = issue.fix else {
            Issue.record("expected a move, got \(String(describing: issue.fix))")
            return
        }
        #expect(id == title.id && to.y < 0.5)
        #expect(critique.stills.first?.score == 100 - issue.cost)

        // A caption sits on a plate: fine anywhere.
        var caption = title
        caption.style = .caption
        let plated = judge([still(2, backdrop: darkTopBrightBottom, texts: [StillMeasurement.Text(id: caption.id, frame: CGRect(x: 0.35, y: 0.77, width: 0.3, height: 0.1))])], snapshot(texts: [caption]))
        #expect(plated.stills.first?.issues.isEmpty == true)
    }

    @Test func movesTextOffTheAction() throws {
        let caption = TextOverlay(text: "Pick a template", span: TimeSpan(start: 0, end: 5), center: CGPoint(x: 0.5, y: 0.84))
        // A click right under the caption: canvas (0.5, 0.84) is source (960, 81).
        let take = AgentEditTake(duration: 20, sourceSize: source, clicks: [ClickEvent(timestamp: 2, location: CGPoint(x: 960, y: 81), button: .left)])
        let critique = judge(
            [still(2, backdrop: grid { _ in 0.2 }, texts: [StillMeasurement.Text(id: caption.id, frame: CGRect(x: 0.35, y: 0.8, width: 0.3, height: 0.08))])],
            snapshot(texts: [caption]),
            take: take
        )
        let issue = try #require(critique.stills.first?.issues.first { $0.kind == .textOverAction })
        guard case let .moveText(_, to)? = issue.fix else {
            Issue.record("expected a move")
            return
        }
        #expect(to.y < 0.75)
    }

    @Test func keepsTextUpLongEnoughToRead() throws {
        let caption = TextOverlay(text: "Share it with your whole team", span: TimeSpan(start: 2, end: 3))
        let critique = judge([still(2.5, texts: [StillMeasurement.Text(id: caption.id, frame: CGRect(x: 0.3, y: 0.8, width: 0.4, height: 0.08))])], snapshot(texts: [caption]))
        let issue = try #require(critique.stills.first?.issues.first { $0.kind == .textTooShort })
        guard case let .extendText(_, until)? = issue.fix else {
            Issue.record("expected an extension")
            return
        }
        #expect(isClose(until, 2 + LaunchDemoRecipe.holdDuration(caption.text), tolerance: 1e-6))
    }

    @Test func aimsAZoomThatMissesTheAction() throws {
        let zoom = ZoomKeyframe(startTime: 4, peakTime: 4.5, endTime: 8, center: CGPoint(x: 0.25, y: 0.5), scale: 2.5, source: .auto)
        let take = AgentEditTake(duration: 20, sourceSize: source, clicks: [ClickEvent(timestamp: 6, location: CGPoint(x: 1700, y: 540), button: .left)])
        let critique = judge([still(6)], snapshot(zooms: [zoom]), take: take)
        let issue = try #require(critique.stills.first?.issues.first { $0.kind == .actionOutOfFrame })
        #expect(issue.fix == .aimZoom(zoom.id, at: CGPoint(x: 1700.0 / 1920, y: 0.5)))
    }

    @Test func easesBackAZoomTooCloseToBeSharp() throws {
        // A small recording zoomed 4× on a 1080p canvas: a quarter of 960 px across 1536.
        let small = AgentEditTake(duration: 20, sourceSize: CGSize(width: 960, height: 540))
        let zoom = ZoomKeyframe(startTime: 4, peakTime: 4.5, endTime: 8, center: CGPoint(x: 0.5, y: 0.5), scale: 4, source: .manual)
        let critique = judge([still(6)], snapshot(zooms: [zoom]), take: small)
        let issue = try #require(critique.stills.first?.issues.first { $0.kind == .soft })
        guard case let .loosenZoom(id, scale)? = issue.fix else {
            Issue.record("expected a looser zoom")
            return
        }
        #expect(id == zoom.id && isClose(scale, ZoomKeyframeEditor.focusScaleRange.lowerBound))
    }

    @Test func aLongStillStretchIsFlaggedOnce() throws {
        let flat = grid { _ in 0.4 }
        let stills = [1.0, 3, 5, 7].map { still($0, backdrop: busy) } + [still(9, backdrop: flat)]
        let critique = judge(stills, snapshot())
        let flagged = critique.stills.filter { $0.issues.contains { $0.kind == .still } }
        try #require(flagged.count == 1)
        #expect(flagged[0].moment.output == 7)
        #expect(flagged[0].issues.first { $0.kind == .still }?.fix == .addMove(.float, span: TimeSpan(start: 1, end: 7)))
        // A flat frame is blank.
        #expect(critique.stills.last?.issues.contains { $0.kind == .blank } == true)
    }

    @Test func otherAppsShowingAreBlurred() throws {
        let piece = TakeAnalysis.Cover.Piece(span: TimeSpan(start: 4, end: 6), rect: CGRect(x: 0.6, y: 0.7, width: 0.2, height: 0.1), share: 0.05)
        var analysis = TakeAnalyzer().analyze(TakeAnalysisInput(duration: 20, frameSize: source, clicks: [], keystrokes: [], cursor: [], screen: nil, speech: nil))
        analysis.covers = [TakeAnalysis.Cover(appName: "Messages", span: piece.span, pieces: [piece], action: .blur)]
        let critique = judge([still(5)], snapshot(), analysis: analysis)
        #expect(critique.stills.first?.issues.first { $0.kind == .otherApp }?.fix == .blur(piece.rect, span: piece.span))

        // Already hidden: fine.
        var hidden = snapshot()
        hidden.editSettings.blurRegions = [BlurRegion(span: piece.span, rect: piece.rect.insetBy(dx: -0.005, dy: -0.005))]
        #expect(judge([still(5)], hidden, analysis: analysis).stills.first?.issues.contains { $0.kind == .otherApp } == false)
    }

    @Test func aWidePictureInATallFrameIsReframed() throws {
        var edit = snapshot()
        edit.editSettings.canvas = CanvasSpec(aspect: .portrait, resolution: .hd1080)
        let critique = judge([still(5)], edit, canvas: CGSize(width: 1080, height: 1920))
        #expect(critique.stills.first?.issues.first { $0.kind == .smallPicture }?.fix == .reframe)
    }

    @Test func judgesTheHookAndTheRhythm() {
        let critique = judge([still(1)], snapshot())
        // No text and no motion in 20 s.
        #expect(critique.overall.map(\.kind) == [.noHook, .longWait])
        #expect(critique.score < 100)

        let title = TextOverlay(text: "Acme", span: TimeSpan(start: 0.2, end: 2.5), style: .title)
        let zooms = stride(from: 1.0, through: 19, by: 3).map { time in
            ZoomKeyframe(startTime: time - 0.5, peakTime: time, endTime: time + 1, center: CGPoint(x: 0.5, y: 0.5), scale: 1.5, source: .manual)
        }
        #expect(judge([still(1)], snapshot(texts: [title], zooms: zooms)).overall.isEmpty)
    }

    @Test func picksTheWorstStills() {
        let critique = Critique(
            stills: [
                StillScore(moment: moment(1), score: 100, issues: []),
                StillScore(moment: moment(2), score: 40, issues: [CritiqueIssue(kind: .blank, cost: 60, message: "", fix: nil)]),
                StillScore(moment: moment(3), score: 70, issues: [CritiqueIssue(kind: .blank, cost: 30, message: "", fix: nil)]),
                StillScore(moment: moment(4), score: 55, issues: [CritiqueIssue(kind: .blank, cost: 45, message: "", fix: nil)])
            ],
            overall: []
        )
        #expect(critique.worst(3).map(\.moment.output) == [2, 4, 3])
        #expect(critique.worst(1).map(\.score) == [40])
        #expect(critique.score == 66)
    }

    @Test func makesTheFixes() throws {
        let title = TextOverlay(text: "Acme 2.0", span: TimeSpan(start: 0, end: 1), center: CGPoint(x: 0.5, y: 0.8), style: .title)
        let zoom = ZoomKeyframe(startTime: 4, peakTime: 4.5, endTime: 8, center: CGPoint(x: 0.5, y: 0.5), scale: 3, source: .auto)
        var edit = snapshot(texts: [title], zooms: [zoom])
        let take = AgentEditTake(duration: 20, sourceSize: source)
        let notes = Critic.apply([
            .moveText(title.id, to: CGPoint(x: 0.5, y: 0.3)),
            .extendText(title.id, untilOutput: 2.5),
            .plateText(title.id),
            .aimZoom(zoom.id, at: CGPoint(x: 0.7, y: 0.5)),
            // Same zoom again: only the first fix for it is made.
            .loosenZoom(zoom.id, scale: 1.5),
            .addMove(.float, span: TimeSpan(start: 10, end: 14)),
            .blur(CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), span: TimeSpan(start: 2, end: 3)),
            .reframe
        ], to: &edit, take: take)
        #expect(notes.count == 7)
        let text = try #require(edit.editSettings.textOverlays.first)
        #expect(isClose(text.center.y, 0.3) && isClose(text.span.end, 2.5) && text.style == .caption)
        let aimed = try #require(edit.keyframes.first)
        #expect(aimed.source == .manual && isClose(aimed.centerX, 0.7) && isClose(aimed.scale, 3))
        #expect(edit.editSettings.cameraMoves.map(\.kind) == [.float])
        #expect(edit.editSettings.blurRegions.count == 1)
        #expect(edit.editSettings.canvas.reframes)
    }
}
