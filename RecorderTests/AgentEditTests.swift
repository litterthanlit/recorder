import CoreGraphics
import Foundation
import Testing
@testable import RecorderCore

/// A 20 s, 1920×1080 take.
private let take = AgentEditTake(duration: 20, sourceSize: CGSize(width: 1920, height: 1080))

private func freshSnapshot() -> EditorSnapshot {
    var settings = ProjectEditSettings()
    settings.setTimeline(EditTimeline(sourceDuration: 20))
    return EditorSnapshot(keyframes: [], editSettings: settings)
}

private func operations(_ list: [JSONValue]) -> [AgentArguments] {
    list.map { AgentArguments($0) }
}

private func failure(_ body: () throws -> Void) -> String? {
    do {
        try body()
        return nil
    } catch let error as AgentToolError {
        return error.message
    } catch {
        return "\(error)"
    }
}

private func timeline(_ snapshot: EditorSnapshot) -> EditTimeline {
    snapshot.editSettings.resolvedTimeline(sourceDuration: 20)
}

/// Kept source spans, rounded to microseconds.
private func sourceSpans(_ snapshot: EditorSnapshot) -> [[Double]] {
    timeline(snapshot).segments.map { [rounded($0.source.start), rounded($0.source.end)] }
}

private func rounded(_ value: Double) -> Double {
    (value * 1_000_000).rounded() / 1_000_000
}

@Suite("Agent timeline edits")
struct AgentTimelineEditTests {
    @Test func cutsSourceRanges() throws {
        var snapshot = freshSnapshot()
        let notes = try AgentEdits.editTimeline(
            &snapshot, operations: operations([["op": "cut", "start": 2, "end": 5]]), take: take, timeBase: .source
        )
        #expect(sourceSpans(snapshot) == [[0, 2], [5, 20]])
        #expect(isClose(timeline(snapshot).outputDuration, 17))
        #expect(notes == ["Cut 2.00–5.00 s."])
    }

    @Test func outputTimesMeanTheEditBeforeTheCall() throws {
        var snapshot = freshSnapshot()
        _ = try AgentEdits.editTimeline(
            &snapshot, operations: operations([["op": "cut", "start": 0, "end": 4]]), take: take, timeBase: .source
        )
        // Output 0 is now source 4. Both cuts are read on that edit, so the first doesn't
        // shift the second.
        _ = try AgentEdits.editTimeline(
            &snapshot,
            operations: operations([["op": "cut", "start": 1, "end": 2], ["op": "cut", "start": "0:06", "end": 8]]),
            take: take,
            timeBase: .output
        )
        #expect(sourceSpans(snapshot) == [[4, 5], [6, 10], [12, 20]])
        #expect(isClose(timeline(snapshot).outputDuration, 13))
    }

    @Test func keepsOnlyTheGivenRanges() throws {
        var snapshot = freshSnapshot()
        let ranges: JSONValue = [["start": 6, "end": 8], ["start": 1, "end": 3], ["start": 2.5, "end": 4]]
        _ = try AgentEdits.editTimeline(
            &snapshot, operations: operations([["op": "keep_only", "ranges": ranges]]), take: take, timeBase: .source
        )
        #expect(sourceSpans(snapshot) == [[1, 4], [6, 8]])
    }

    @Test func trimsAndChangesSpeed() throws {
        var snapshot = freshSnapshot()
        _ = try AgentEdits.editTimeline(
            &snapshot,
            operations: operations([
                ["op": "trim", "start": "0:01", "end": 18],
                ["op": "speed", "start": 4, "end": 8, "speed": 2]
            ]),
            take: take,
            timeBase: .source
        )
        let result = timeline(snapshot)
        #expect(sourceSpans(snapshot) == [[1, 4], [4, 8], [8, 18]])
        #expect(result.segments.map(\.speed) == [1, 2, 1])
        #expect(isClose(result.outputDuration, 15))
    }

    @Test func trimmingPastACutCutsEverythingBefore() throws {
        var snapshot = freshSnapshot()
        _ = try AgentEdits.editTimeline(
            &snapshot,
            operations: operations([["op": "cut", "start": 3, "end": 6], ["op": "trim", "start": 8]]),
            take: take,
            timeBase: .source
        )
        #expect(sourceSpans(snapshot) == [[8, 20]])
        // An earlier start grows the edit back.
        _ = try AgentEdits.editTimeline(
            &snapshot, operations: operations([["op": "trim", "start": 7]]), take: take, timeBase: .source
        )
        #expect(sourceSpans(snapshot) == [[7, 20]])
    }

    @Test func resetsToTheWholeRecording() throws {
        var snapshot = freshSnapshot()
        _ = try AgentEdits.editTimeline(
            &snapshot, operations: operations([["op": "cut", "start": 2, "end": 5]]), take: take, timeBase: .source
        )
        _ = try AgentEdits.editTimeline(&snapshot, operations: operations([["op": "reset"]]), take: take, timeBase: .source)
        #expect(sourceSpans(snapshot) == [[0, 20]])
    }

    @Test func explainsBadOperations() {
        var snapshot = freshSnapshot()
        let original = snapshot

        let outside = failure {
            _ = try AgentEdits.editTimeline(
                &snapshot, operations: operations([["op": "cut", "start": 25, "end": 30]]), take: take, timeBase: .source
            )
        }
        #expect(outside == "operations[0] (cut): 25–30 s is outside the recording (0–20 s).")

        let everything = failure {
            _ = try AgentEdits.editTimeline(
                &snapshot, operations: operations([["op": "cut", "start": 0, "end": 20]]), take: take, timeBase: .source
            )
        }
        #expect(everything == "operations[0] (cut): That would cut everything; keep at least part of the video.")

        let unknown = failure {
            _ = try AgentEdits.editTimeline(
                &snapshot,
                operations: operations([["op": "cut", "start": 1, "end": 2], ["op": "explode"]]),
                take: take,
                timeBase: .source
            )
        }
        #expect(unknown == "operations[1] (explode): Unknown op \"explode\". Use cut, keep_only, trim, speed or reset.")

        let tooFast = failure {
            _ = try AgentEdits.editTimeline(
                &snapshot,
                operations: operations([["op": "speed", "start": 1, "end": 2, "speed": 40]]),
                take: take,
                timeBase: .source
            )
        }
        #expect(tooFast == "operations[0] (speed): speed must be between 0.25 and 16 (got 40).")

        let empty = failure {
            _ = try AgentEdits.editTimeline(&snapshot, operations: [], take: take, timeBase: .source)
        }
        #expect(empty == "operations is empty.")

        // A call that fails changes nothing, even after operations that worked.
        #expect(snapshot == original)
    }
}

@Suite("Agent zoom edits")
struct AgentZoomEditTests {
    @Test func addsAZoomOnABox() throws {
        var snapshot = freshSnapshot()
        // The top-right quarter, as an agent reads it off a frame.
        let box: JSONValue = ["x": 0.5, "y": 0, "width": 0.5, "height": 0.5]
        _ = try AgentEdits.editZooms(
            &snapshot, operations: operations([["op": "add", "start": 2, "end": 5, "rect": box]]), take: take, timeBase: .source
        )
        let zoom = try #require(snapshot.keyframes.first)
        #expect(zoom.source == .manual)
        #expect(isClose(zoom.startTime, 2) && isClose(zoom.endTime, 5))
        #expect(zoom.peakTime > zoom.startTime && zoom.peakTime < zoom.endTime)
        #expect(isClose(zoom.scale, 2))
        // Bottom-left origin inside Trace: the top-right quarter is centred at y 0.75.
        #expect(isClose(zoom.centerX, 0.75) && isClose(zoom.centerY, 0.75))
    }

    @Test func updatesAndRemovesZooms() throws {
        var snapshot = freshSnapshot()
        _ = try AgentEdits.editZooms(
            &snapshot,
            operations: operations([["op": "add", "start": 2, "duration": 3, "point": ["x": 0.2, "y": 0.2], "scale": 2]]),
            take: take,
            timeBase: .source
        )
        let id = try #require(snapshot.keyframes.first?.id)
        _ = try AgentEdits.editZooms(
            &snapshot,
            operations: operations([["op": "update", "zoom_id": .string(id.uuidString), "start": 10, "point": ["x": 0.5, "y": 0.5], "scale": 1.5]]),
            take: take,
            timeBase: .source
        )
        let updated = try #require(snapshot.keyframes.first)
        #expect(updated.id == id)
        // It keeps its length when only the start moves.
        #expect(isClose(updated.startTime, 10) && isClose(updated.endTime, 13))
        #expect(isClose(updated.scale, 1.5))
        #expect(isClose(updated.centerX, 0.5) && isClose(updated.centerY, 0.5))

        _ = try AgentEdits.editZooms(
            &snapshot, operations: operations([["op": "remove", "zoom_ids": [.string(id.uuidString)]]]), take: take, timeBase: .source
        )
        #expect(snapshot.keyframes.isEmpty)
    }

    @Test func remakesAutoZoomsAndKeepsManualOnes() throws {
        let clicks = [
            ClickEvent(timestamp: 5, location: CGPoint(x: 400, y: 300), button: .left),
            ClickEvent(timestamp: 11, location: CGPoint(x: 1500, y: 800), button: .left)
        ]
        let clicky = AgentEditTake(duration: 20, sourceSize: CGSize(width: 1920, height: 1080), clicks: clicks)
        var snapshot = freshSnapshot()
        _ = try AgentEdits.editZooms(
            &snapshot,
            operations: operations([
                ["op": "add", "start": 15, "duration": 2, "point": ["x": 0.5, "y": 0.5]],
                ["op": "auto", "preset": "punch"]
            ]),
            take: clicky,
            timeBase: .source
        )
        #expect(snapshot.keyframes.filter { $0.source == .auto }.count == 2)
        #expect(snapshot.keyframes.filter { $0.source == .manual }.count == 1)
        #expect(snapshot.editSettings.zoomPreset == .punch)
        #expect(snapshot.keyframes.map(\.startTime) == snapshot.keyframes.map(\.startTime).sorted())

        _ = try AgentEdits.editZooms(
            &snapshot, operations: operations([["op": "remove", "which": "auto"]]), take: clicky, timeBase: .source
        )
        #expect(snapshot.keyframes.map(\.source) == [.manual])
    }

    @Test func aZoomNeedsATarget() {
        var snapshot = freshSnapshot()
        let message = failure {
            _ = try AgentEdits.editZooms(
                &snapshot, operations: operations([["op": "add", "start": 2, "end": 4]]), take: take, timeBase: .source
            )
        }
        #expect(message?.hasPrefix("operations[0] (add): Say where to zoom") == true)
        let missing = failure {
            _ = try AgentEdits.editZooms(
                &snapshot,
                operations: operations([["op": "update", "zoom_id": .string(UUID().uuidString)]]),
                take: take,
                timeBase: .source
            )
        }
        #expect(missing?.contains("No zoom has the zoom_id") == true)
    }
}

@Suite("Agent text and blur edits")
struct AgentTextAndBlurEditTests {
    @Test func addsTextWhereAndWhenAsked() throws {
        var snapshot = freshSnapshot()
        _ = try AgentEdits.editText(
            &snapshot,
            operations: operations([["op": "add", "text": "Ship faster", "style": "title", "start": 1, "position": "lower_third"]]),
            take: take,
            timeBase: .source
        )
        let overlay = try #require(snapshot.editSettings.textOverlays.first)
        #expect(overlay.style == .title)
        #expect(overlay.center == CGPoint(x: 0.5, y: 0.7))
        // Long enough to read.
        #expect(isClose(overlay.span.start, 1) && isClose(overlay.span.duration, AgentEdits.readingDuration("Ship faster")))
        #expect(AgentEdits.readingDuration("Ship faster") >= 2)

        _ = try AgentEdits.editText(
            &snapshot,
            operations: operations([["op": "update", "text_id": .string(overlay.id.uuidString), "text": "Ship today", "position": ["x": 0.25, "y": 0.1]]]),
            take: take,
            timeBase: .source
        )
        let updated = try #require(snapshot.editSettings.textOverlays.first)
        #expect(updated.text == "Ship today")
        #expect(updated.center == CGPoint(x: 0.25, y: 0.1))
        #expect(updated.style == .title)

        _ = try AgentEdits.editText(&snapshot, operations: operations([["op": "remove", "all": true]]), take: take, timeBase: .source)
        #expect(snapshot.editSettings.textOverlays.isEmpty)
    }

    @Test func textOnTheOutputClockLandsOnTheRecording() throws {
        var snapshot = freshSnapshot()
        _ = try AgentEdits.editTimeline(
            &snapshot, operations: operations([["op": "cut", "start": 0, "end": 4]]), take: take, timeBase: .source
        )
        _ = try AgentEdits.editText(
            &snapshot,
            operations: operations([["op": "add", "text": "Hi", "start": 1, "end": 3]]),
            take: take,
            timeBase: .output
        )
        let overlay = try #require(snapshot.editSettings.textOverlays.first)
        #expect(isClose(overlay.span.start, 5) && isClose(overlay.span.end, 7))
        #expect(overlay.style == .caption)
    }

    @Test func explainsBadPositions() {
        var snapshot = freshSnapshot()
        let message = failure {
            _ = try AgentEdits.editText(
                &snapshot,
                operations: operations([["op": "add", "text": "Hi", "start": 1, "position": "middle"]]),
                take: take,
                timeBase: .source
            )
        }
        #expect(message?.hasPrefix("operations[0] (add): position must be one of \"top\"") == true)
        let noText = failure {
            _ = try AgentEdits.editText(&snapshot, operations: operations([["op": "add", "start": 1]]), take: take, timeBase: .source)
        }
        #expect(noText == "operations[0] (add): text is required.")
    }

    @Test func hidesBoxesForTheWholeTakeByDefault() throws {
        var snapshot = freshSnapshot()
        let box: JSONValue = ["x": 0.1, "y": 0.1, "width": 0.2, "height": 0.1]
        _ = try AgentEdits.editBlur(&snapshot, operations: operations([["op": "add", "rect": box, "kind": "pixelate"]]), take: take, timeBase: .source)
        let region = try #require(snapshot.editSettings.blurRegions.first)
        #expect(isClose(region.span.start, 0) && isClose(region.span.end, 20))
        #expect(region.kind == .pixelate)
        // Near the top of the frame: high y with Trace's bottom-left origin.
        #expect(isClose(region.rect, CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.1)))

        _ = try AgentEdits.editBlur(
            &snapshot,
            operations: operations([["op": "update", "blur_id": .string(region.id.uuidString), "strength": 1, "start": 2, "end": 6]]),
            take: take,
            timeBase: .source
        )
        let updated = try #require(snapshot.editSettings.blurRegions.first)
        #expect(updated.strength == 1)
        #expect(isClose(updated.span.start, 2) && isClose(updated.span.end, 6))

        _ = try AgentEdits.editBlur(
            &snapshot, operations: operations([["op": "remove", "blur_id": .string(region.id.uuidString)]]), take: take, timeBase: .source
        )
        #expect(snapshot.editSettings.blurRegions.isEmpty)

        let noRect = failure {
            _ = try AgentEdits.editBlur(&snapshot, operations: operations([["op": "add"]]), take: take, timeBase: .source)
        }
        #expect(noRect?.hasPrefix("operations[0] (add): rect is required") == true)
    }
}

@Suite("Agent style edits")
struct AgentStyleEditTests {
    @Test func appliesALookThenSettingsOnTop() throws {
        let clicks = [ClickEvent(timestamp: 5, location: CGPoint(x: 400, y: 300), button: .left)]
        let clicky = AgentEditTake(duration: 20, sourceSize: CGSize(width: 1920, height: 1080), clicks: clicks)
        var snapshot = freshSnapshot()
        let arguments = AgentArguments([
            "look": "vivid",
            "aspect": "9:16",
            "padding": 0.05,
            "shadow": false,
            "watermark": " acme.com ",
            "microphone_volume": 1.5
        ])
        let notes = try AgentEdits.setStyle(&snapshot, arguments: arguments, take: clicky)
        let settings = snapshot.editSettings
        #expect(settings.zoomPreset == .punch)
        #expect(settings.exportStyle.background.wallpaper == .aurora)
        #expect(settings.canvas.aspect == .portrait)
        #expect(isClose(settings.exportStyle.paddingRatio, 0.05))
        #expect(!settings.exportStyle.shadowEnabled)
        #expect(settings.exportStyle.watermarkEnabled && settings.exportStyle.watermarkText == "acme.com")
        #expect(isClose(settings.audio.microphoneVolume, 1.5))
        // The look's zoom preset remade the automatic zooms.
        #expect(snapshot.keyframes.filter { $0.source == .auto }.count == 1)
        #expect(notes.first == "Applied the Vivid look.")
    }

    @Test func setsBackgrounds() throws {
        var snapshot = freshSnapshot()
        _ = try AgentEdits.setStyle(
            &snapshot,
            arguments: AgentArguments(["background": ["from": "#6E56CF", "to": "0ea5e9", "angle": 90]]),
            take: take
        )
        var background = snapshot.editSettings.exportStyle.background
        #expect(background.kind == .gradient)
        #expect(background.gradientStart.hexString == "#6E56CF")
        #expect(background.gradientEnd.hexString == "#0EA5E9")
        #expect(background.gradientAngle == 90)

        _ = try AgentEdits.setStyle(&snapshot, arguments: AgentArguments(["background": ["kind": "none"]]), take: take)
        background = snapshot.editSettings.exportStyle.background
        #expect(background.kind == .none)

        _ = try AgentEdits.setStyle(&snapshot, arguments: AgentArguments(["background": ["wallpaper": "ocean"]]), take: take)
        background = snapshot.editSettings.exportStyle.background
        #expect(background.kind == .wallpaper && background.wallpaper == .ocean)
    }

    @Test func explainsBadStyles() {
        var snapshot = freshSnapshot()
        let nothing = failure { _ = try AgentEdits.setStyle(&snapshot, arguments: AgentArguments(["take_id": "latest"]), take: take) }
        #expect(nothing?.hasPrefix("Nothing to change") == true)
        let look = failure { _ = try AgentEdits.setStyle(&snapshot, arguments: AgentArguments(["look": "Neon"]), take: take) }
        #expect(look?.hasPrefix("No look is called \"Neon\". Looks: \"Midnight\"") == true)
        let color = failure {
            _ = try AgentEdits.setStyle(&snapshot, arguments: AgentArguments(["background": ["color": "+12345"]]), take: take)
        }
        #expect(color == "color must be a hex colour like \"#6E56CF\" (got \"+12345\").")
        let aspect = failure { _ = try AgentEdits.setStyle(&snapshot, arguments: AgentArguments(["aspect": "7:3"]), take: take) }
        #expect(aspect?.hasPrefix("aspect must be one of 16:9") == true)
        let padding = failure { _ = try AgentEdits.setStyle(&snapshot, arguments: AgentArguments(["padding": 0.5]), take: take) }
        #expect(padding == "padding must be between 0 and 0.3 (got 0.5).")
    }

    @Test func readsResolutionNames() {
        #expect(AgentEdits.parseResolution("4K") == .uhd2160)
        #expect(AgentEdits.parseResolution(" 1080p ") == .hd1080)
        #expect(AgentEdits.parseResolution("source") == .source)
        #expect(AgentEdits.parseResolution("8k") == nil)
    }
}

@Suite("Agent edit catalog")
struct AgentEditCatalogTests {
    @Test func everyEditToolTakesATake() {
        let editing = ["edit_timeline", "edit_zooms", "edit_text", "edit_blur", "set_style", "undo", "export_video"]
        for name in editing {
            let tool = AgentToolCatalog.tool(named: name)
            #expect(tool != nil, "\(name) is missing")
            let required = tool?.inputSchema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            #expect(required.contains("take_id"), "\(name) doesn't require take_id")
        }
        #expect(AgentToolCatalog.tool(named: "export_status") != nil)
    }

    @Test func textPositionsMatchTheSchema() {
        let named = AgentToolCatalog.textPosition["anyOf"]?.arrayValue?.first?["enum"]?.arrayValue?.compactMap(\.stringValue)
        #expect(named == AgentEdits.textPositions.map { $0.name })
    }
}
