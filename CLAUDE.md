# Trace: notes for coding agents

Trace (the repo, target and module are still called Recorder): a native macOS 14+ menu
bar screen recorder for product demos. Area/window/display capture, auto zoom on clicks,
a multi-track editor (cuts, speed and ramps, crop, zooms, animated text, blur, keystrokes,
cut transitions, 3D moves, looks), MP4, HEVC, ProRes and GIF export, and an MCP server
(`Trace --mcp`) so AI agents can edit and export takes. Swift 5 language mode, SwiftUI +
AppKit, ScreenCaptureKit, AVFoundation, Core Image. README.md lists features; DEMO.md is
the user-facing workflow.

## Verifying changes

- Cloud sessions run on Linux: there is no Swift toolchain or Xcode. Push to the working
  branch and let `.github/workflows/ci.yml` (macos-15) check it: `swift test`, a signing
  build-settings check, an `xcodebuild` app build with signing off, and
  `scripts/mcp-smoke.py` against the built `Trace --mcp`. Read results with
  the GitHub MCP tools (`actions_list` → `list_workflow_runs` / `list_workflow_jobs`,
  `get_job_logs`). Job logs are large: fetch with `tail_lines` and grep for `error:` and
  `✘`.
- CI proves it compiles and the pure logic is right. Capture, preview and export have not
  run on a real Mac since the redesign (September 2026); say so rather than claiming they
  work. See [Verify on a Mac](#verify-on-a-mac).
- Testable logic belongs in the SwiftPM target `RecorderCore`: everything under `Agent/`,
  `Zoom/`, `Composition/`, `Models/` and `Timeline/`, plus `Editor/ZoomKeyframeEditor.swift` and
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
  `TextPlateLayout`, so the selection box fits the drawn text. The source crop
  (`ProjectEditSettings.sourceCrop`, `SourceCrop`) comes first: it's where the zoom rests
  (`ZoomInterpolator(base:)`) and sets the content size the canvas follows. `RenderFeatures`
  gates the newer effects (animated text, cut transitions, 3D moves) so default settings
  take the old path. Transitions are timed in output time (the renderer takes
  `outputTime`); 3D moves warp the framed picture with `CIPerspectiveTransform` over a
  backdrop drawn without its flat shadow.
- **Speed ramps** (`EditTimeline.speedRamp`) ease speed changes between touching segments:
  only the mapping inside a segment and `compositionPlan` change, never a segment's output
  duration. `AudioEnvelope` fades audio at cuts and silences pieces above 2.5×
  (`AudioMixSettings.cutFades` / `muteSpedUp`).
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
- **Agents (MCP)**: `TraceMain` runs `MCPStdioServer` for `--mcp` (never creating
  `AppState`). `MCPServer` (Core, both protocol eras) answers `tools/list` and prompts
  itself and forwards `tools/call` over a Unix socket (`AgentBridge`, same user only) to
  the app's `AgentToolHost` (main actor, `App/Agent/`), which `AgentBridgeController`
  starts while Settings › Agents › "Allow AI agents" is on. Edits are pure functions over
  `EditorSnapshot` in Core (`AgentEdits`, `AgentStyleEdits`, `LaunchDemoRecipe`); an open
  take is changed through `ProjectEditor.applyExternalEdit` (one undo step), a closed one
  is saved with `ProjectStore.saveEdits` and its undo kept in `AgentEditJournal`, which
  hands it to the editor when the take opens. `TakeAnalyzer` (Core) finds what to cut
  from the recorded input plus `AgentMediaScanner`'s frame times, screen changes and mic
  speech. New takes record which app was in front (`AppFocusSampler` → `InputLog.appFocus`).
- **UI map**: `UI/EditorView.swift` (layout and key commands), `UI/Editor/` (toolbar,
  inspector panels, selection inspector, canvas overlays, transport, export sheet),
  `UI/TimelineView.swift` + `UI/Timeline/` (tracks, thumbnails and waveform), `UI/Capture/`
  (selector, HUD, Quick Access), `UI/Library/`, `UI/Settings/`, `UI/Design/DesignSystem.swift`
  (tokens and button styles). The editor window's toolbar is an `NSToolbar` whose items
  host SwiftUI views (`EditorToolbarController`).
- **Storage**: `ProjectStore` in `Models/Project.swift`. Projects live in
  `~/Movies/Trace/<uuid>.recorder/`; `LibraryMigration` moves bundles from the old
  `~/Movies/Recorder`. `ProjectFormat.current` (3 since the crop, transitions, 3D moves
  and text animation) versions settings and metadata: a newer project is refused, never
  overwritten. Decoding is tolerant (`decodeIfPresent ?? default`,
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
- Agent tools: a new tool needs an `MCPTool` in `AgentToolCatalog.tools` (that order is
  the `tools/list` order, which clients cache) and a case in `AgentToolHost.run`
  (`AgentBridgeController.swift`); edits go through `AgentEditTools.apply` so each call is
  one undo step named `AgentEdits.actionPrefix + …`. Agents see rects and points
  normalized with a top-left origin (`AgentCoordinates` converts) and times in source
  seconds unless `time_base` is `"output"`. Errors are `AgentToolError`s that say how to
  fix the call. In `--mcp` mode nothing but JSON-RPC may reach stdout (the smoke test
  fails on any other line).
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
  - Key paths into tuples (`plan.map(\.speed)` on an array of tuples); use a closure.
  - Enum cases called `none` next to Optionals (`.none` means `nil` there); pick another
    name, like `straight`.

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
8. **Agents**: turn on Settings › Agents, run `claude mcp add --scope user trace --
   …/Trace.app/Contents/MacOS/Trace --mcp`, and list the tools with
   `npx @modelcontextprotocol/inspector …/Trace --mcp`. With Trace quit, a call launches it
   hidden (no panel or onboarding); with access off, a call returns the instructions and
   launches nothing. An open take updates live and ⌘Z undoes "Agent: …"; a closed take's
   edit is saved, the `undo` tool reverts it, and opening the take afterwards keeps that
   history. `view_frames` (rendered) matches the export; `export_video` writes a file.
9. **App focus**: a take with a detour into another app has `appFocus` in `inputs.json`
   (no window titles), Trace's own panel doesn't count, and `set_crop app` frames exactly
   the window, on a Retina display and on a second display with a negative origin.
10. **Crop and motion**: preview matches export for a crop, each text animation, smooth
    speed changes (audio in step), transitions with audio fades and muting, and 3D moves
    (the shadow follows the tilted picture, the spotlight the cursor). The preview lies
    flat while aiming a zoom, cropping or editing blur.
11. **make_launch_demo** on a messy take (idle start, a detour, a slow page load): the
    result reads well at 16:9 and 9:16, and `analyze_take` on a ten-minute take finishes
    within a couple of minutes.

Known limits: resizing a window mid-take isn't followed (the capture size is fixed at
start); the cursor sprite ignores the Accessibility cursor-size setting; GIFs are capped
at 30 s and 720 px wide. App focus follows only the frontmost app's front window. Text
animations and 3D moves are timed in source time, so they play faster inside sped-up
parts. A 3D tilt needs a look with a background. Agents edit and export; they don't
record, and can't choose a picture background.
