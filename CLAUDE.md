# Trace: notes for coding agents

Trace (the repo, target and module are still called Recorder): a native macOS 14+ menu
bar screen recorder for product demos. Area/window/display capture, auto zoom on clicks,
a multi-track editor (cuts, speed, zooms, text, blur, keystrokes, looks) and MP4, HEVC,
ProRes and GIF export. Swift 5 language mode, SwiftUI + AppKit, ScreenCaptureKit,
AVFoundation, Core Image. README.md lists features; DEMO.md is the user-facing workflow.

## Verifying changes

- Cloud sessions run on Linux: there is no Swift toolchain or Xcode. Push to the working
  branch and let `.github/workflows/ci.yml` (macos-15) check it: `swift test`, a signing
  build-settings check, and an `xcodebuild` app build with signing off. Read results with
  the GitHub MCP tools (`actions_list` → `list_workflow_runs` / `list_workflow_jobs`,
  `get_job_logs`). Job logs are large: fetch with `tail_lines` and grep for `error:` and
  `✘`.
- CI proves it compiles and the pure logic is right. Capture, preview and export have not
  run on a real Mac since the redesign (September 2026); say so rather than claiming they
  work. See [Verify on a Mac](#verify-on-a-mac).
- Testable logic belongs in the SwiftPM target `RecorderCore`: everything under `Zoom/`,
  `Composition/`, `Models/` and `Timeline/`, plus `Editor/ZoomKeyframeEditor.swift` and
  `Editor/EditHistory.swift`. Core files import Foundation/CoreGraphics only (no AppKit,
  SwiftUI or AVFoundation); colours are `RGBAColor`. App-only files added to `Editor/`
  need a Package.swift `exclude` entry. Tests use Swift Testing, one suite file per area
  in `RecorderTests/`, with `isClose` and `TemporaryDirectory` in `TestSupport.swift`.

## Architecture

- **Two time domains.** Source time (t = 0 at the first captured frame) holds clicks,
  cursor, keystrokes, cursor shapes, zooms, text, blur regions and the camera track.
  Output time is the edited video: playhead, timeline UI, export clock. Only
  `EditTimeline` converts (`sourceTime(forOutput:)`, `outputTime(forSource:)`,
  `outputTimeClamped`). Segments are never reordered, so source time never decreases
  along the output and the exporter reads the recording once, in order.
- **Pause** shifts timestamps (`PauseLedger` behind `RecordingClock`) rather than leaving
  gaps; the take is split at pause points when it's saved.
- **Rendering.** `CompositionRenderer` draws preview and export alike, from
  `CompositionRenderSettings(project:editSettings:)`: blur regions, ripples and the cursor
  in source space; then the zoom crop fitted on the background; then spotlight, camera,
  text, keystrokes and watermark in output space. Fixed sizes are designed at 1080p and
  scaled by `CanvasLayout.referenceUnit`. Text layout is shared with the canvas through
  `TextPlateLayout`, so the selection box fits the drawn text.
- **Preview**: `AVPlayer` plays a composition of the edit (`TimelineCompositionBuilder`);
  `CompositorPreviewHost` renders each display-link tick into an
  `AVSampleBufferDisplayLayer`, mapping player time to source time.
- **Export**: `ExportService` → `VideoExporter` (`ExportFrameSource` on a
  `ConstantFrameRateTimeline`, holding the latest source frame because ScreenCaptureKit
  only delivers frames when the screen changes) → AVAssetWriter or `GIFWriter`. Writes go
  to a temporary file and are moved into place; `exports.json` records the latest export.
- **Editor** (`ProjectEditor`, main actor): `keyframes` and `editSettings` are
  `private(set)`; change them through its methods or `settingBinding(_:actionName:)` so
  undo records it. Sliders pass `continuous: true` and wrap the drag in
  `beginInteractiveEdit` / `endInteractiveEdit` (`EditorSlider` does this) so a drag is one
  undo step. The playhead lives in `EditorPlayback` so 20 Hz ticks only redraw views that
  observe it. One `EditorSelection` (clip, zoom, text, blur) drives the inspector and canvas.
- **UI map**: `UI/EditorView.swift` (layout and key commands), `UI/Editor/` (toolbar,
  inspector panels, selection inspector, canvas overlays, transport, export sheet),
  `UI/TimelineView.swift` + `UI/Timeline/` (tracks, thumbnails and waveform), `UI/Capture/`
  (selector, HUD, Quick Access), `UI/Library/`, `UI/Settings/`, `UI/Design/DesignSystem.swift`
  (tokens and button styles). The editor window's toolbar is an `NSToolbar` whose items
  host SwiftUI views (`EditorToolbarController`).
- **Storage**: `ProjectStore` in `Models/Project.swift`. Projects live in
  `~/Movies/Trace/<uuid>.recorder/`; `LibraryMigration` moves bundles from the old
  `~/Movies/Recorder`. `ProjectFormat.current` versions settings and metadata: a newer
  project is refused, never overwritten. Decoding is tolerant (`decodeIfPresent ?? default`,
  enums with fallback `init(from:)`), and legacy keys (`trimStart`/`trimEnd`,
  `backgroundEnabled`) are still written. Saving goes through `ProjectAutosaver`.
  Looks: `~/Library/Application Support/Trace/styles.json`. Export and recording
  preferences are in UserDefaults.

## Conventions and gotchas

- The Xcode project is edited by hand. `scripts/pbxproj-add.py <group path> File.swift…`
  adds the PBXFileReference, PBXBuildFile, group child and Sources entry with the next
  free IDs (and creates missing groups); `--remove File.swift…` undoes it.
- Coordinates: click and cursor positions, zoom centres, blur rects and crop rects use a
  bottom-left origin (Core Image space), in source pixels or normalized 0–1. Text overlay
  centres are normalized canvas coordinates with a top-left origin. SwiftUI is top-left:
  map with `ZoomKeyframeEditor.sourceRect(forSelection:…)`, `viewRect(forSource:…)` and
  `unclippedSourceRect(forView:…)`. In the renderer, bitmaps are drawn in unflipped
  contexts; a mismatch here once mirrored every overlay.
- Clocks: t = 0 is the first screen frame's host time. Clicks, keys, mic audio (converted
  from the capture session clock) and the camera track are placed relative to it.
- The app icon is generated: `python3 scripts/make-icon.py` rewrites
  `Assets.xcassets/AppIcon.appiconset`.
- Signing: `Config/Signing.xcconfig` is the target's base config; a git-ignored
  `Config/Local.xcconfig` (from `scripts/configure-signing.sh`) sets the team. Bundle ID
  `app.hypher.recorder`, product name Trace.
- Swift mistakes that broke builds before:
  - `guard let x` shadowing a property already used earlier in the same scope ("use of
    local variable before its declaration"); name the binding differently.
  - `try` inside a ternary; mutating calls inside `#expect` (assign to a local first);
    exact `==` on computed floating-point values in tests.
  - A `CodingKeys` case without a matching property breaks synthesized `Encodable`; read
    legacy keys through a separate key enum.
  - Big SwiftUI view bodies time out the type checker: split them into small views and
    computed properties, and give ternaries explicit types.
  - Name clashes between views and Core types (a view called `TimelineRuler` hid the Core
    enum): check before naming a view.

## Verify on a Mac

Nothing below has run on real hardware. In rough order of risk:

1. **Capture**: area on a second display, including one left of or above the main
   display (negative origin); window capture following a moved window; the app's own
   windows (panel, selector, HUD, countdown, bubble) absent from recordings; Finder and
   Notification Center exclusion; "hide menu bar and Dock" on a notched MacBook.
2. **Pause/resume** with mic and system audio: no gaps or drift after several pauses.
3. **Keystrokes**: the Input Monitoring prompt, and nothing recorded in secure fields.
4. **Editor**: preview matches export (orientation, colour, cursor size, text position);
   thumbnails and waveform load; trimming, speed changes and scrubbing keep audio in step;
   aiming a zoom, dragging text and blur boxes; keyboard shortcuts don't fire while typing;
   the toolbar items lay out in the unified toolbar.
5. **Export**: MP4, HEVC, ProRes and GIF open in QuickTime, Final Cut and a browser;
   cancel mid-way leaves no file; exports to a chosen folder; sped-up audio length
   matches the video; a 5K display exports (HEVC path); GIF memory stays reasonable at
   30 s.
6. **Library migration** from `~/Movies/Recorder`, and that renaming the app to Trace
   kept the Screen Recording and Accessibility permissions.
7. `scripts/release.sh` end to end with a Developer ID certificate.

Known limits: resizing a window mid-take isn't followed (the capture size is fixed at
start); the cursor sprite ignores the Accessibility cursor-size setting; GIFs are capped
at 30 s and 720 px wide.
