import CoreGraphics
import Foundation
import Testing
@testable import RecorderCore

private let wide = CGSize(width: 1920, height: 1080)

private func click(_ time: TimeInterval, x: CGFloat, y: CGFloat = 540) -> ClickEvent {
    ClickEvent(timestamp: time, location: CGPoint(x: x, y: y), button: .left)
}

/// A take where the action is on the left for five seconds, then on the right.
private func leftThenRight() -> AgentEditTake {
    let clicks = stride(from: 0.5, through: 5, by: 0.5).map { click($0, x: 200) }
        + stride(from: 10, through: 15, by: 0.5).map { click($0, x: 1700) }
    return AgentEditTake(duration: 20, sourceSize: wide, clicks: clicks)
}

private func settings(aspect: OutputAspect, crop: CGRect? = nil, reframes: Bool = true) -> ProjectEditSettings {
    var settings = ProjectEditSettings()
    settings.canvas = CanvasSpec(aspect: aspect, resolution: .hd1080, reframes: reframes)
    settings.sourceCrop = crop
    return settings
}

@Suite("Reframing")
struct ReframeTests {
    @Test func aTallFrameFollowsTheAction() throws {
        let reframing = try #require(Reframer.reframe(settings(aspect: .portrait), keyframes: [], take: leftThenRight()))
        #expect(reframing.aspect == .portrait)
        // 9:16 out of 16:9: the full height and 0.316 of the width.
        let width: CGFloat = (9.0 / 16.0) / (16.0 / 9.0)
        #expect(isClose(reframing.crop.height, 1) && isClose(reframing.crop.width, width, tolerance: 1e-6))
        let path = try #require(reframing.path)
        let early = path.rect(at: 2)
        let late = path.rect(at: 14)
        // On the left while the action is there, on the right once it moves.
        #expect(early.minX < 0.05)
        #expect(late.maxX > 0.95)
        for time in stride(from: 0.0, through: 20, by: 0.25) {
            let rect = path.rect(at: time)
            #expect(isClose(rect.width, width, tolerance: 1e-6) && isClose(rect.height, 1, tolerance: 1e-6))
            #expect(rect.minX >= -1e-9 && rect.maxX <= 1 + 1e-9)
        }
    }

    @Test func itStaysInsideTheCrop() throws {
        let window = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let reframing = try #require(Reframer.reframe(settings(aspect: .square, crop: window), keyframes: [], take: leftThenRight()))
        // A square of the window's height (0.5 of 1080 px is 540 px: 0.28125 of the width).
        #expect(isClose(reframing.crop.height, 0.5) && isClose(reframing.crop.width, 0.28125, tolerance: 1e-6))
        let path = try #require(reframing.path)
        for time in stride(from: 0.0, through: 20, by: 0.5) {
            let rect = path.rect(at: time)
            #expect(rect.minX >= 0.25 - 1e-9 && rect.maxX <= 0.75 + 1e-9)
            #expect(rect.minY >= 0.25 - 1e-9 && rect.maxY <= 0.75 + 1e-9)
        }
        #expect(path.rect(at: 2).minX < 0.26 && path.rect(at: 14).maxX > 0.74)
    }

    @Test func jitterDoesNotMoveIt() {
        // Clicks wandering a little around the middle: the frame holds still.
        let clicks = (0..<30).map { index in click(Double(index) * 0.5, x: 960 + (index % 2 == 0 ? 40 : -40)) }
        let take = AgentEditTake(duration: 16, sourceSize: wide, clicks: clicks)
        let reframing = Reframer.reframe(settings(aspect: .portrait), keyframes: [], take: take)
        #expect(reframing != nil && reframing?.path == nil)
        #expect(reframing.map { isClose($0.crop.midX, 0.5, tolerance: 0.03) } == true)
    }

    @Test func zoomsSayWhereToLook() throws {
        // No clicks; a zoom holding on the right from 4 s.
        let zoom = ZoomKeyframe(startTime: 3, peakTime: 4, endTime: 9, center: CGPoint(x: 0.85, y: 0.5), scale: 2, source: .manual)
        let take = AgentEditTake(duration: 12, sourceSize: wide)
        let reframing = try #require(Reframer.reframe(settings(aspect: .portrait), keyframes: [zoom], take: take))
        #expect(reframing.crop.maxX > 0.95 || (reframing.path?.rect(at: 7).maxX ?? 0) > 0.95)
    }

    @Test func theSameShapeNeedsNone() {
        #expect(Reframer.reframe(settings(aspect: .widescreen), keyframes: [], take: leftThenRight()) == nil)
        #expect(Reframer.reframe(settings(aspect: .auto), keyframes: [], take: leftThenRight()) == nil)
        // A 16:9 window in a 16:9 recording, at 16:9: nothing to do.
        let window = CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
        #expect(Reframer.reframe(settings(aspect: .widescreen, crop: window), keyframes: [], take: leftThenRight()) == nil)
    }

    @Test func whatTheVideoShowsFollowsTheReframing() throws {
        var settings = settings(aspect: .portrait)
        settings.reframe = try #require(Reframer.reframe(settings, keyframes: [], take: leftThenRight()))
        // The picture is the reframing: its shape is the canvas's.
        let content = settings.contentSize(source: wide)
        #expect(isClose(content.width / content.height, 9.0 / 16.0, tolerance: 1e-3))
        #expect(settings.cropBase(at: 14).maxX > 0.95)
        // For another shape it doesn't apply.
        settings.canvas.aspect = .square
        #expect(settings.activeReframe == nil)
        #expect(settings.contentSize(source: wide) == wide)
    }

    @Test func itIsSavedAndReadBack() throws {
        var settings = settings(aspect: .portrait)
        settings.reframe = Reframer.reframe(settings, keyframes: [], take: leftThenRight())
        let decoded = try JSONDecoder().decode(ProjectEditSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        #expect(decoded.canvas.reframes)
        // Canvases saved before reframing fit the whole picture.
        let older = try JSONDecoder().decode(CanvasSpec.self, from: Data(#"{"aspect":"portrait","resolution":"hd1080"}"#.utf8))
        #expect(!older.reframes)
    }

    @Test func itIsRefreshedWhenWhatItFollowsChanges() throws {
        let take = leftThenRight()
        var snapshot = EditorSnapshot(keyframes: [], editSettings: settings(aspect: .portrait))
        snapshot.refreshReframe(take: take, since: nil)
        let first = try #require(snapshot.editSettings.reframe)

        // Text doesn't change it; a new shape does.
        var texted = snapshot
        texted.editSettings.textOverlays = [TextOverlay(text: "Hi", span: TimeSpan(start: 1, end: 3))]
        let before = snapshot
        texted.refreshReframe(take: take, since: before)
        #expect(texted.editSettings.reframe == first)

        var square = snapshot
        square.editSettings.canvas.aspect = .square
        square.refreshReframe(take: take, since: before)
        #expect(square.editSettings.reframe?.aspect == .square)

        // Turned off, it goes.
        var fitted = snapshot
        fitted.editSettings.canvas.reframes = false
        fitted.refreshReframe(take: take, since: before)
        #expect(fitted.editSettings.reframe == nil)
    }
}

@Suite("Other shapes from one timeline")
struct ShapeVariantTests {
    @Test func aVariantReframesAndKeepsTextClearOfAppControls() throws {
        var settings = ProjectEditSettings()
        settings.setTimeline(EditTimeline(sourceDuration: 20))
        settings.textOverlays = [
            TextOverlay(text: "Title", span: TimeSpan(start: 0, end: 2), center: CGPoint(x: 0.5, y: 0.42), style: .title),
            TextOverlay(text: "Caption", span: TimeSpan(start: 3, end: 5), center: CGPoint(x: 0.5, y: 0.84))
        ]
        let original = EditorSnapshot(keyframes: [], editSettings: settings)
        let vertical = original.variant(for: .portrait, reframe: true, take: leftThenRight())
        // The same timeline and text, reframed for 9:16, the caption moved up out of the
        // controls at the bottom.
        #expect(vertical.editSettings.timeline == settings.timeline)
        #expect(vertical.editSettings.canvas.aspect == .portrait && vertical.editSettings.canvas.reframes)
        #expect(vertical.editSettings.activeReframe != nil)
        #expect(vertical.editSettings.textOverlays.map(\.center.y) == [0.42, 0.75])
        // Square: text stays put; without reframing it's just the shape.
        let square = original.variant(for: .square, reframe: false, take: leftThenRight())
        #expect(square.editSettings.reframe == nil && square.editSettings.canvas.aspect == .square)
        #expect(square.editSettings.textOverlays.map(\.center.y) == [0.42, 0.84])
        // Its own shape: unchanged.
        #expect(original.variant(for: .widescreen, reframe: false, take: leftThenRight()) == original)
    }
}

@Suite("Agents and reframing")
struct AgentReframeTests {
    private func blank() -> EditorSnapshot {
        var settings = ProjectEditSettings()
        settings.setTimeline(EditTimeline(sourceDuration: 20))
        return EditorSnapshot(keyframes: [], editSettings: settings)
    }

    @Test func setStyleTurnsReframingOnAndOff() throws {
        var snapshot = blank()
        let before = snapshot
        let notes = try AgentEdits.setStyle(&snapshot, arguments: AgentArguments(["aspect": "9:16", "reframe": true]), take: leftThenRight())
        #expect(notes.contains("Reframes to fill the shape, following the clicks, typing and zooms."))
        // As the edit tools do after every edit.
        snapshot.refreshReframe(take: leftThenRight(), since: before)
        #expect(snapshot.editSettings.activeReframe?.aspect == .portrait)

        let on = snapshot
        _ = try AgentEdits.setStyle(&snapshot, arguments: AgentArguments(["reframe": false]), take: leftThenRight())
        snapshot.refreshReframe(take: leftThenRight(), since: on)
        #expect(snapshot.editSettings.reframe == nil)
    }

    @Test func aLaunchDemoForReelsIsReframed() throws {
        var options = LaunchDemoOptions()
        options.aspect = .portrait
        let analysis = TakeAnalyzer().analyze(TakeAnalysisInput(
            duration: 20,
            frameSize: wide,
            clicks: leftThenRight().clicks,
            keystrokes: [],
            cursor: [],
            screen: nil,
            speech: nil
        ))
        var snapshot = blank()
        let report = try LaunchDemoRecipe(options: options).apply(to: &snapshot, take: leftThenRight(), analysis: analysis)
        #expect(snapshot.editSettings.canvas.reframes)
        #expect(snapshot.editSettings.activeReframe != nil)
        #expect(report.changes.contains("Reframed for 9:16: the frame follows the clicks, typing and zooms."))

        // Asked not to, it fits the whole picture.
        options.reframe = false
        var fitted = blank()
        _ = try LaunchDemoRecipe(options: options).apply(to: &fitted, take: leftThenRight(), analysis: analysis)
        #expect(!fitted.editSettings.canvas.reframes && fitted.editSettings.reframe == nil)
    }

    @Test func shapesAreReadFromAList() throws {
        #expect(try AgentAspect.parseList(["16:9", "9x16", "square", "9:16"], key: "aspects") == [.widescreen, .portrait, .square])
        #expect(throws: AgentToolError.self) { try AgentAspect.parseList([], key: "aspects") }
        #expect(throws: AgentToolError.self) { try AgentAspect.parseList(["21:9"], key: "aspects") }
    }
}
