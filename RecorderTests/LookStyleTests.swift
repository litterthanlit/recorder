import CoreGraphics
import Foundation
import Testing
@testable import RecorderCore

@Suite("Look styles")
struct LookStyleTests {
    @Test func colorsRoundTripThroughHex() {
        let color = RGBAColor(hex: "#6E56CF")
        #expect(color.hexString == "#6E56CF")
        #expect(isClose(RGBAColor.white.luminance, 1))
        #expect(isClose(RGBAColor.black.luminance, 0))
    }

    @Test func wallpapersKnowIfTheyAreDark() {
        #expect(WallpaperPreset.midnight.isDark)
        #expect(WallpaperPreset.graphite.isDark)
        #expect(!WallpaperPreset.snow.isDark)
        #expect(!WallpaperPreset.sky.isDark)
    }

    @Test func oldStylesKeepTheirBackground() throws {
        let off = try JSONDecoder().decode(ExportStyle.self, from: Data(#"{ "backgroundEnabled": false }"#.utf8))
        #expect(off.background.kind == .none)
        #expect(!off.backgroundEnabled)
        let on = try JSONDecoder().decode(ExportStyle.self, from: Data(#"{ "backgroundEnabled": true }"#.utf8))
        #expect(on.background.kind == .wallpaper && on.background.wallpaper == .midnight)
        let unknownKind = try JSONDecoder().decode(ExportStyle.self, from: Data(#"{ "background": { "kind": "video" } }"#.utf8))
        #expect(unknownKind.background.kind == .wallpaper)
    }

    @Test func stylesStillWriteTheLegacyBackgroundFlag() throws {
        var style = ExportStyle()
        style.background.kind = .none
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(style)) as? [String: Any])
        #expect(object["backgroundEnabled"] as? Bool == false)
        let decoded = try JSONDecoder().decode(ExportStyle.self, from: JSONEncoder().encode(style))
        #expect(decoded == style)
    }

    @Test func turningTheFrameBackOnRestoresAWallpaper() {
        var style = ExportStyle()
        style.background.kind = .gradient
        style.backgroundEnabled = false
        #expect(style.background.kind == .none)
        style.backgroundEnabled = true
        #expect(style.background.kind == .wallpaper)
        style.background.kind = .solid
        style.backgroundEnabled = true
        #expect(style.background.kind == .solid)
    }

    @Test func cameraSizeFollowsTheSlider() {
        var camera = CameraOverlayStyle()
        #expect(isClose(camera.diameterFraction, 0.18))
        camera.customSize = 0.3
        #expect(isClose(camera.diameterFraction, 0.3))
        camera.customSize = 0.9
        #expect(isClose(camera.diameterFraction, 0.4))
    }

    @Test func idleCursorFadesOutAndBackIn() {
        let activity: [TimeInterval] = [0, 0.5, 1.0, 6.0]
        #expect(CursorVisibility.opacity(at: 3, activity: activity, hideWhenIdle: false) == 1)
        #expect(CursorVisibility.opacity(at: 1.2, activity: activity, hideWhenIdle: true) == 1)
        #expect(isClose(CursorVisibility.opacity(at: 2.625, activity: activity, hideWhenIdle: true), 0.5))
        #expect(CursorVisibility.opacity(at: 4, activity: activity, hideWhenIdle: true) == 0)
        #expect(isClose(CursorVisibility.opacity(at: 5.875, activity: activity, hideWhenIdle: true), 0.5))
        #expect(CursorVisibility.opacity(at: 6, activity: activity, hideWhenIdle: true) == 1)
    }
}

@Suite("Timeline items")
struct TimelineItemTests {
    @Test func textFadesInAndOut() {
        let text = TextOverlay(text: "Hello", span: TimeSpan(start: 2, end: 4))
        #expect(text.opacity(at: 1.9) == 0)
        #expect(isClose(text.opacity(at: 2.1), 0.5))
        #expect(text.opacity(at: 3) == 1)
        #expect(isClose(text.opacity(at: 3.9), 0.5))
        #expect(text.opacity(at: 4.1) == 0)
    }

    @Test func itemsDecodeTolerantly() throws {
        let json = #"{ "text": "Hi", "span": { "start": 1, "end": 2 }, "style": "banner" }"#
        let text = try JSONDecoder().decode(TextOverlay.self, from: Data(json.utf8))
        #expect(text.style == .caption)
        #expect(text.scale == 1)

        let blurJSON = #"{ "span": { "start": 1, "end": 2 }, "rect": [[0.1, 0.2], [0.3, 0.4]] }"#
        let blur = try JSONDecoder().decode(BlurRegion.self, from: Data(blurJSON.utf8))
        #expect(blur.kind == .blur)
        #expect(blur.isActive(at: 1.5) && !blur.isActive(at: 2.5))
    }

    @Test func settingsKeepOverlaysThroughARoundTrip() throws {
        var settings = ProjectEditSettings()
        settings.textOverlays = [TextOverlay(text: "Step 1", span: TimeSpan(start: 0, end: 3), style: .title)]
        settings.blurRegions = [BlurRegion(span: TimeSpan(start: 1, end: 5), rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1), kind: .pixelate)]
        let decoded = try JSONDecoder().decode(ProjectEditSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }
}

@Suite("Keystroke overlay")
struct KeystrokeOverlayTests {
    private func key(_ time: TimeInterval, _ code: UInt32, _ modifiers: UInt32 = 0, _ characters: String? = nil) -> KeystrokeEvent {
        KeystrokeEvent(timestamp: time, keyCode: code, modifiers: modifiers, characters: characters)
    }

    @Test func typingMergesIntoOnePill() {
        let events = [key(1, 0x04, 0, "h"), key(1.2, 0x0E, 0, "e"), key(1.4, 0x25, 0, "y")]
        let pills = KeystrokeOverlayTimeline.pills(from: events, filter: .all)
        #expect(pills.count == 1)
        #expect(pills[0].text == "hey")
        #expect(isClose(pills[0].span.start, 1))
        #expect(isClose(pills[0].span.end, 1.4 + KeystrokeOverlayTimeline.holdDuration))
    }

    @Test func repeatedShortcutsCount() {
        let command = KeyCombo.Modifier.command
        let events = [key(1, 0x06, command, "z"), key(1.5, 0x06, command, "z"), key(2, 0x06, command, "z")]
        let pills = KeystrokeOverlayTimeline.pills(from: events, filter: .shortcuts)
        #expect(pills.map(\.text) == ["⌘Z ×3"])
    }

    @Test func shortcutsOnlyHidesTyping() {
        let events = [key(1, 0x04, 0, "h"), key(2, 0x28, KeyCombo.Modifier.command, "k")]
        let pills = KeystrokeOverlayTimeline.pills(from: events, filter: .shortcuts)
        #expect(pills.map(\.text) == ["⌘K"])
        #expect(KeystrokeOverlayTimeline.pills(from: events, filter: .off).isEmpty)
    }

    @Test func aNewPillReplacesTheLastOne() {
        let events = [key(1, 0x28, KeyCombo.Modifier.command, "k"), key(1.5, KeyNames.Code.returnKey, 0, "\r")]
        let pills = KeystrokeOverlayTimeline.pills(from: events, filter: .shortcuts)
        #expect(pills.count == 2)
        #expect(isClose(pills[0].span.end, 1.5))
        #expect(KeystrokeOverlayTimeline.pill(at: 1.7, in: pills)?.pill.text == "↩")
        #expect(KeystrokeOverlayTimeline.pill(at: 5, in: pills) == nil)
    }
}

@Suite("Style presets")
struct StylePresetTests {
    @Test func applyingKeepsCameraVisibilityAndSmoothing() {
        var settings = ProjectEditSettings()
        settings.camera.isVisible = false
        settings.exportStyle.cursorSmoothingEnabled = false
        let preset = StylePreset.builtIn.first { $0.name == "Vertical Social" }!
        preset.apply(to: &settings)
        #expect(settings.canvas.aspect == .portrait)
        #expect(settings.exportStyle.background.wallpaper == .candy)
        #expect(settings.zoomPreset == .punch)
        #expect(!settings.camera.isVisible)
        #expect(!settings.exportStyle.cursorSmoothingEnabled)
    }

    @Test func savedPresetsCaptureTheLook() throws {
        var settings = ProjectEditSettings()
        settings.exportStyle.cornerRadius = 30
        settings.camera.shape = .roundedSquare
        let preset = StylePreset(name: "Mine", from: settings)
        var library = StyleLibrary(presets: [preset], defaultPresetID: preset.id)
        #expect(library.defaultPreset?.name == "Mine")
        #expect(library.allPresets.count == StylePreset.builtIn.count + 1)
        #expect(!library.isBuiltIn(preset))
        library.defaultPresetID = StylePreset.builtIn[0].id
        #expect(library.defaultPreset?.name == "Midnight")

        let decoded = try JSONDecoder().decode(StyleLibrary.self, from: JSONEncoder().encode(library))
        #expect(decoded == library)
    }
}
