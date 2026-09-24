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
  IDs (`A2…` file references, last used `A2000000000000000000002A`; `B2…` build files, last
  used `B20000000000000000000026`). Add it to Package.swift too if it belongs in
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

## Backlog (from the audit, most valuable first)

1. Verify on a Mac, then fix what's found: window capture (`SCContentFilter(display:including:)`
   likely records the whole display squeezed into the window's size; use
   `SCContentFilter(desktopIndependentWindow:)` or set `sourceRect`), the preview
   (AVSampleBufferDisplayLayer path: orientation, colour), cursor size, and the Dock toggle.
2. Capture target: add a display picker (only the main display is recorded; the countdown
   and bubble use `NSScreen.main`), and exclude the app's own windows from capture
   (`SCContentFilter(display:excludingApplications:exceptingWindows:)`).
3. Hiding the menu bar doesn't work (`presentationOptions` only apply while this app is
   frontmost); crop it out with `sourceRect` instead.
4. 5K/6K displays: H.264 at native Retina size likely fails; use HEVC or cap the size, and
   round capture dimensions to even numbers.
5. Timeline: resize handles for zooms (`updateSelectedKeyframeStart/End` already exist),
   editing a zoom's center, bigger trim handles, VoiceOver labels, keyboard nudging.
6. System audio (`SCStreamConfiguration.capturesAudio`), camera bubble size, and the
   watermark/bubble overlap in the bottom-right corner.
7. Smoothed cursor: time-based smoothing that settles when the mouse stops, using clicks as
   anchors; show I-beam and pointing-hand cursors.
8. Distribution: Developer ID signing and a notarization script.
