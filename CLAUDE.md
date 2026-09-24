# Recorder: notes for coding agents

Native macOS (13+) menu bar screen recorder with auto-zoom on clicks, a timeline editor,
and MP4 export. Swift 5 language mode, SwiftUI + AppKit, ScreenCaptureKit, AVFoundation,
Core Image. See README.md for features and DEMO.md for the recording workflow it serves.

## Verifying changes

- Cloud sessions run on Linux: there is no Swift toolchain or Xcode. Push to the working
  branch and let `.github/workflows/ci.yml` (macos-15) check it: `swift test`, a signing
  build-settings check, and an `xcodebuild` app build with signing off. Read results with
  the GitHub MCP tools (`actions_list` → `list_workflow_runs` / `list_workflow_jobs`,
  `get_job_logs`).
- CI proves it compiles and the pure logic is right. Capture, preview, and export behaviour
  has not been exercised on a real Mac since the September 2026 audit; say so rather than
  claiming it works.
- Testable logic belongs in the SwiftPM target `RecorderCore` (Package.swift `sources`:
  `Zoom/`, `Composition/`, `Editor/ZoomKeyframeEditor.swift`, `Editor/EditHistory.swift`).
  Tests use Swift Testing in `RecorderTests/RecorderTests.swift`.

## Conventions and gotchas

- The Xcode project is edited by hand. A new source file needs a PBXBuildFile, a
  PBXFileReference, a group child, and a Sources build-phase entry, using the sequential
  IDs (`A2…` file references, last used `A2000000000000000000002C`; `B2…` build files, last
  used `B20000000000000000000028`). Add it to Package.swift too if it belongs in
  `RecorderCore`.
- Coordinates: click and cursor positions, zoom centers, and crop rects use a bottom-left
  origin (Core Image space), in source pixels or normalized 0–1. SwiftUI is top-left; map
  preview selections with `ZoomKeyframeEditor.sourceRect(forSelection:contentFrame:visibleCrop:)`.
  Overlay drawing in `CompositionRenderer` must stay consistent (the cursor sprite is drawn
  in a flipped context; ripples and masks are not). A mismatch here once mirrored every overlay.
- Clocks: t = 0 is the first screen frame's host time. Clicks, mic audio (converted from the
  capture session clock), and the camera track (`camera.mov`) are all placed relative to it.
- ScreenCaptureKit only delivers frames when the screen changes, so export runs on a fixed
  output clock (`ConstantFrameRateTimeline`) and holds the latest source frame.
- Editor state (`keyframes`, `editSettings`) is `private(set)`. Change it through
  `ProjectEditor` methods or `settingBinding(_:actionName:)` so undo records it; wrap drags
  and sliders in `beginInteractiveEdit` / `endInteractiveEdit` so they are one undo step.
- Saving goes through `ProjectAutosaver` (debounced, background, atomic writes). Projects
  live in `~/Movies/Recorder/<uuid>.recorder/`.
- Signing: `Config/Signing.xcconfig` is the target's base config; a git-ignored
  `Config/Local.xcconfig` (written by `scripts/configure-signing.sh`) sets the team.
  Bundle ID `app.hypher.recorder`.
- Swift mistakes that broke builds before: a `guard let x` that shadows a property already
  used earlier in the same scope ("use of local variable before its declaration"); `try`
  inside a ternary; exact `==` on floating-point results in tests.

## Backlog

The September 2026 audit backlog was worked through in code (commits on
`claude/peaceful-newton-k7tcg7`), but none of it has run on a real Mac yet. What's left:

1. Verify on a Mac, in this order, and fix what's found:
   - Window capture (now `SCContentFilter(desktopIndependentWindow:)`): output is just the
     window, clicks land on the right spot, zooms follow.
   - Display picker with two displays, including one left of / above the main display
     (negative global origin): countdown and bubble on the recorded display, clicks mapped.
   - The app's own windows (panel, countdown, bubble) absent from display recordings.
   - "Hide menu bar & dock": menu bar cropped via `sourceRect`, Dock auto-hides and is
     restored, on a notched MacBook too.
   - A 5K/6K display records and exports (HEVC path).
   - System audio: recorded, excluded from our own app, mixed with the mic on export;
     check the editor preview plays both tracks.
   - Preview (`AVSampleBufferDisplayLayer` path): orientation and colour match export.
   - Cursor: smoothed arrow settles and hits clicks; its size matches the real cursor
     (the sprite ignores the Accessibility cursor-size setting).
   - Timeline: edge-resize, trim handles, ⌥-arrow nudging, VoiceOver.
   - `scripts/release.sh` end to end with a Developer ID certificate.
2. Clicks in window mode use the window's frame at record start; a window moved during
   the take maps clicks wrongly. Track the window frame (or drop clicks outside it).
3. Show I-beam and pointing-hand cursors (record the cursor type with each sample).
4. Editing a zoom's center on the preview (manual zoom mode only creates new zooms).
5. The live on-screen camera bubble is a fixed 168 pt; the size setting only affects export.
