import CoreGraphics
import Foundation
import Testing
@testable import RecorderCore

private func summary(_ name: String?, created: TimeInterval, app: String? = nil, id: UUID = UUID()) -> ProjectSummary {
    var metadata = ProjectMetadata(
        id: id, createdAt: Date(timeIntervalSince1970: created), width: 1920, height: 1080, fps: 60, duration: 30,
        scaleFactor: 2, captureOriginX: 0, captureOriginY: 0, captureWidth: 960, captureHeight: 540,
        captureTarget: app == nil ? .display : .area, appName: app
    )
    metadata.name = name
    return ProjectSummary(metadata: metadata, bundleURL: URL(fileURLWithPath: "/tmp/\(id.uuidString).recorder"))
}

private func errorMessage(_ body: () throws -> Void) -> String? {
    do {
        try body()
        return nil
    } catch let error as AgentToolError {
        return error.message
    } catch {
        return "\(error)"
    }
}

@Suite("Agent arguments")
struct AgentArgumentTests {
    @Test func readsTypedValues() throws {
        let arguments = AgentArguments([
            "name": "Intro", "count": 3, "ratio": "0.5", "on": "yes", "off": false,
            "time": "1:05.5", "nothing": .null, "list": [1, 2], "object": ["x": 1]
        ])
        #expect(try arguments.string("name") == "Intro")
        #expect(try arguments.int("count") == 3)
        #expect(try arguments.double("ratio") == 0.5)
        #expect(try arguments.bool("on") == true)
        #expect(try arguments.bool("off") == false)
        #expect(try arguments.time("time") == 65.5)
        #expect(try arguments.string("nothing") == nil)
        #expect(!arguments.has("nothing"))
        #expect(try arguments.array("list")?.count == 2)
        #expect(try arguments.object("object")?.int("x") == 1)
    }

    @Test func explainsWhatsWrong() {
        let arguments = AgentArguments(["name": 3, "count": 2.5, "speed": 40, "flag": "maybe", "base": "wall"])
        #expect(errorMessage { _ = try arguments.string("name") } == "name must be a string.")
        #expect(errorMessage { _ = try arguments.int("count") } == "count must be a whole number.")
        #expect(errorMessage { _ = try arguments.double("speed", in: 0.25...16) } == "speed must be between 0.25 and 16 (got 40).")
        #expect(errorMessage { _ = try arguments.bool("flag") } == "flag must be true or false.")
        #expect(errorMessage { _ = try arguments.choice("base", AgentTimeBase.self) } == "base must be one of \"source\", \"output\" (got \"wall\").")
        #expect(errorMessage { _ = try arguments.requiredString("missing") } == "missing is required.")
    }

    @Test func choicesIgnoreCaseAndDashes() throws {
        #expect(try AgentArguments(["time_base": "OUTPUT"]).choice("time_base", AgentTimeBase.self) == .output)
        #expect(try AgentTimeBase.read(AgentArguments([:])) == .source)
    }

    @Test func parsesTimes() {
        #expect(AgentTime.parse(12.5) == 12.5)
        #expect(AgentTime.parse("12.5") == 12.5)
        #expect(AgentTime.parse("12.5s") == 12.5)
        #expect(AgentTime.parse("1:05.2").map { isClose($0, 65.2) } == true)
        #expect(AgentTime.parse("1:02:03") == 3723)
        #expect(AgentTime.parse("1:75") == nil)
        #expect(AgentTime.parse("-3") == nil)
        #expect(AgentTime.parse("soon") == nil)
        #expect(AgentTime.parse(.null) == nil)
    }

    @Test func readsListsOfObjects() throws {
        let arguments = AgentArguments(["operations": [["op": "cut"], ["op": "trim"]], "bad": [["op": "cut"], 3]])
        #expect(try arguments.objects("operations")?.compactMap { try $0.string("op") } == ["cut", "trim"])
        #expect(errorMessage { _ = try arguments.objects("bad") } == "bad[1] must be an object.")
    }
}

@Suite("Agent coordinates and clocks")
struct AgentCoordinateTests {
    @Test func flipsBetweenTopLeftAndBottomLeft() {
        let topLeft = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let source = AgentCoordinates.sourceRect(fromTopLeft: topLeft)
        #expect(isClose(source, CGRect(x: 0.1, y: 0.4, width: 0.3, height: 0.4)))
        #expect(isClose(AgentCoordinates.topLeftRect(fromSource: source), topLeft))
        let point = AgentCoordinates.sourcePoint(fromTopLeft: CGPoint(x: 0.25, y: 0.1))
        #expect(isClose(point.y, 0.9))
        #expect(isClose(AgentCoordinates.topLeftPoint(fromSource: point).y, 0.1))
    }

    @Test func readsAndChecksRects() throws {
        let rect = try AgentCoordinates.sourceRect(AgentArguments(["x": 0.5, "y": 0, "width": 0.5, "height": 0.25]))
        #expect(isClose(rect, CGRect(x: 0.5, y: 0.75, width: 0.5, height: 0.25)))
        #expect(errorMessage { _ = try AgentCoordinates.sourceRect(AgentArguments(["x": 0.8, "y": 0, "width": 0.5, "height": 0.2])) }?
            .hasPrefix("rect must lie within 0–1") == true)
        #expect(errorMessage { _ = try AgentCoordinates.sourceRect(AgentArguments(["x": 0.1])) }?
            .hasPrefix("rect needs x, y, width and height") == true)
    }

    @Test func roundsForAgents() {
        let json = AgentCoordinates.json(sourceRect: CGRect(x: 0.123456, y: 0.5, width: 0.25, height: 0.25))
        #expect(json["x"]?.doubleValue == 0.1235)
        #expect(json["y"]?.doubleValue == 0.25)
    }

    @Test func outputTimesMapThroughTheEdit() {
        // Keep 0–4 and 6–10: output 5 is source 7.
        let timeline = EditTimeline(
            segments: [
                EditSegment(source: TimeSpan(start: 0, end: 4)),
                EditSegment(source: TimeSpan(start: 6, end: 10))
            ],
            sourceDuration: 10
        )
        #expect(isClose(AgentTimeBase.output.sourceTime(5, in: timeline), 7))
        #expect(isClose(AgentTimeBase.source.sourceTime(5, in: timeline), 5))
        let span = AgentTimeBase.output.sourceSpan(TimeSpan(start: 1, end: 5), in: timeline)
        #expect(isClose(span.start, 1) && isClose(span.end, 7))
    }
}

@Suite("Finding takes")
struct TakeResolverTests {
    private let takes = [
        summary("Onboarding demo", created: 100),
        summary("Pricing page", created: 300, app: "Safari"),
        summary("Pricing page v2", created: 200)
    ]

    @Test func latestIsTheNewest() throws {
        #expect(try TakeResolver.resolve(nil, in: takes).displayName == "Pricing page")
        #expect(try TakeResolver.resolve("latest", in: takes).displayName == "Pricing page")
        #expect(try TakeResolver.resolve("  ", in: takes).displayName == "Pricing page")
    }

    @Test func findsByIDExactNameOrUniquePart() throws {
        let id = takes[0].id
        #expect(try TakeResolver.resolve(id.uuidString, in: takes).id == id)
        #expect(try TakeResolver.resolve("pricing PAGE", in: takes).displayName == "Pricing page")
        #expect(try TakeResolver.resolve("onboarding", in: takes).displayName == "Onboarding demo")
    }

    @Test func explainsMissingAndAmbiguousTakes() {
        #expect(errorMessage { _ = try TakeResolver.resolve("pric", in: takes) }?.hasPrefix("Several takes match \"pric\"") == true)
        #expect(errorMessage { _ = try TakeResolver.resolve("nope", in: takes) }?.hasPrefix("No take is called \"nope\"") == true)
        #expect(errorMessage { _ = try TakeResolver.resolve(UUID().uuidString, in: takes) }?.hasPrefix("No take has the id") == true)
        #expect(errorMessage { _ = try TakeResolver.resolve("latest", in: []) }?.hasPrefix("Trace's library has no takes") == true)
    }

    @Test func readsAspectNames() {
        #expect(AgentAspect.parse("16:9") == .widescreen)
        #expect(AgentAspect.parse("9x16") == .portrait)
        #expect(AgentAspect.parse("1/1") == .square)
        #expect(AgentAspect.parse("Reels") == .portrait)
        #expect(AgentAspect.parse("square") == .square)
        #expect(AgentAspect.parse("7:3") == nil)
        #expect(AgentAspect.name(.vertical) == "4:5")
    }
}

@Suite("Frame sampling")
struct FrameSamplingTests {
    @Test func spreadsTimesEvenly() {
        let times = FrameSampling.evenlySpaced(count: 4, in: TimeSpan(start: 0, end: 8))
        #expect(times == [1, 3, 5, 7])
        #expect(FrameSampling.evenlySpaced(count: 3, in: TimeSpan(start: 2, end: 2)) == [2])
        #expect(FrameSampling.evenlySpaced(count: 0, in: TimeSpan(start: 0, end: 8)).isEmpty)
    }

    @Test func fitsWithoutUpscaling() {
        #expect(FrameSampling.fitted(CGSize(width: 3840, height: 2160), longEdge: 1280) == CGSize(width: 1280, height: 720))
        #expect(FrameSampling.fitted(CGSize(width: 1080, height: 1920), longEdge: 1280) == CGSize(width: 720, height: 1280))
        #expect(FrameSampling.fitted(CGSize(width: 640, height: 360), longEdge: 1280) == CGSize(width: 640, height: 360))
    }

    @Test func sheetsFitTheBudgetWithoutOverlap() {
        for count in [1, 4, 12, 24] {
            let layout = FrameSampling.sheetLayout(count: count, tileAspect: 16.0 / 9.0)
            #expect(layout.columns * layout.rows >= count)
            #expect(layout.size.width <= CGFloat(FrameSampling.maximumLongEdge) + 0.5)
            #expect(layout.size.height <= CGFloat(FrameSampling.maximumLongEdge) + 0.5)
            let frames = (0..<count).map(layout.tileFrame)
            for (index, frame) in frames.enumerated() {
                #expect(frame.maxX <= layout.size.width && frame.maxY + layout.labelHeight <= layout.size.height)
                for other in frames[(index + 1)...] {
                    #expect(!frame.intersects(other))
                }
            }
        }
        // Twelve 16:9 tiles: a few columns, each reasonably large.
        let twelve = FrameSampling.sheetLayout(count: 12, tileAspect: 16.0 / 9.0)
        #expect(twelve.tileSize.width >= 300)
    }
}

@Suite("Take descriptions")
struct TakeDescriptionTests {
    private func project(settings: ProjectEditSettings = ProjectEditSettings()) -> RecorderProject {
        let metadata = ProjectMetadata(
            id: UUID(), createdAt: Date(timeIntervalSince1970: 0), width: 1920, height: 1080, fps: 60, duration: 20,
            scaleFactor: 2, captureOriginX: 0, captureOriginY: 0, captureWidth: 960, captureHeight: 540,
            captureTarget: .area, appName: "Acme"
        )
        return RecorderProject(metadata: metadata, clickEvents: [], keyframes: [], editSettings: settings)
    }

    @Test func listsRemovedSourceTime() {
        let timeline = EditTimeline(
            segments: [
                EditSegment(source: TimeSpan(start: 1, end: 4)),
                EditSegment(source: TimeSpan(start: 6, end: 18))
            ],
            sourceDuration: 20
        )
        let removed = TakeDescription.removedSpans(timeline, duration: 20)
        #expect(removed == [TimeSpan(start: 0, end: 1), TimeSpan(start: 4, end: 6), TimeSpan(start: 18, end: 20)])
    }

    @Test func describesAnEditedTake() throws {
        var settings = ProjectEditSettings()
        settings.setTimeline(EditTimeline(
            segments: [EditSegment(source: TimeSpan(start: 0, end: 5)), EditSegment(source: TimeSpan(start: 10, end: 20), speed: 2)],
            sourceDuration: 20
        ))
        settings.blurRegions = [BlurRegion(span: TimeSpan(start: 1, end: 2), rect: CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.1))]
        settings.canvas.aspect = .portrait
        let take = project(settings: settings)
        let detail = TakeDescription.detail(project: take, keyframes: [], editSettings: settings, isOpen: true)

        #expect(detail["output_duration"]?.doubleValue == 10)
        #expect(detail["app"]?.stringValue == "Acme")
        #expect(detail["open_in_editor"]?.boolValue == true)
        #expect(detail["canvas"]?["aspect"]?.stringValue == "9:16")
        let segments = try #require(detail["timeline"]?["segments"]?.arrayValue)
        #expect(segments.count == 2)
        #expect(segments[1]["speed"]?.doubleValue == 2)
        #expect(segments[1]["output"]?["start"]?.doubleValue == 5)
        // A blur box near the top of the frame (bottom-left y 0.7–0.8) reads as y 0.2 for agents.
        let rect = try #require(detail["blur"]?.arrayValue?.first?["rect"])
        #expect(rect["y"]?.doubleValue == 0.2)

        let entry = TakeDescription.listEntry(
            summary: ProjectSummary(metadata: take.metadata, bundleURL: URL(fileURLWithPath: "/tmp/x.recorder")),
            metadata: take.metadata,
            editSettings: settings,
            isOpen: false
        )
        #expect(entry["edited"]?.boolValue == true)
        #expect(entry["output_duration"]?.doubleValue == 10)
        #expect(entry["capture"]?.stringValue == "area")
    }

    @Test func listsTheAppsInFront() {
        var take = project()
        #expect(TakeDescription.detail(project: take, keyframes: [], editSettings: take.editSettings, isOpen: false)["apps_in_front"] == nil)
        take.inputs.appFocus = [
            AppFocusEvent(timestamp: 0, bundleID: "com.acme.app", appName: "Acme", windowRect: nil),
            AppFocusEvent(timestamp: 15, bundleID: "com.apple.Safari", appName: "Safari", windowRect: nil)
        ]
        let detail = TakeDescription.detail(project: take, keyframes: [], editSettings: take.editSettings, isOpen: false)
        let apps = detail["apps_in_front"]?.arrayValue ?? []
        #expect(apps.compactMap { $0["name"]?.stringValue } == ["Acme", "Safari"])
        #expect(apps.first?["seconds"]?.doubleValue == 15)
    }

    @Test func anUntouchedTakeIsNotEdited() {
        let take = project()
        let settings = take.editSettings
        let timeline = settings.resolvedTimeline(sourceDuration: 20)
        #expect(!TakeDescription.isEdited(settings, timeline: timeline, duration: 20))
    }
}

@Suite("Agent setup and catalog")
struct AgentCatalogTests {
    @Test func quotesPathsForTheShell() {
        #expect(AgentSetup.shellQuoted("/Applications/Trace.app/Contents/MacOS/Trace") == "/Applications/Trace.app/Contents/MacOS/Trace")
        #expect(AgentSetup.shellQuoted("/Users/me/My Apps/Trace") == "'/Users/me/My Apps/Trace'")
        #expect(AgentSetup.shellQuoted("/tmp/it's") == "'/tmp/it'\\''s'")
        #expect(AgentSetup.claudeCodeCommand(executable: "/A/Trace") == "claude mcp add --scope user trace -- /A/Trace --mcp")
    }

    @Test func clientConfigIsValidJSON() throws {
        let config = AgentSetup.clientConfig(executable: "/Applications/Trace.app/Contents/MacOS/Trace")
        let parsed = try JSONValue.parse(Data(config.utf8))
        #expect(parsed["mcpServers"]?["trace"]?["command"]?.stringValue == "/Applications/Trace.app/Contents/MacOS/Trace")
        #expect(parsed["mcpServers"]?["trace"]?["args"] == JSONValue.array(["--mcp"]))
    }

    @Test func toolsAreWellFormed() {
        let tools = AgentToolCatalog.tools
        let names = tools.map(\.name)
        #expect(Set(names).count == names.count)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        for tool in tools {
            #expect(tool.name.unicodeScalars.allSatisfy { allowed.contains($0) })
            #expect(!tool.description.isEmpty)
            let schema = tool.inputSchema
            #expect(schema["type"]?.stringValue == "object")
            let properties = schema["properties"]?.objectValue ?? [:]
            for required in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
                #expect(properties[required] != nil, "\(tool.name) requires \(required) but doesn't describe it")
            }
        }
        // The same order every time (clients cache the list).
        #expect(AgentToolCatalog.tools.map(\.name) == names)
    }
}
