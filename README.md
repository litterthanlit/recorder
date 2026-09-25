# Recorder

Native macOS screen recorder with **automatic zoom on clicks** — built for Screen Studio–style Hypher launch demos.

## Features

- Menu bar app — record a full display (pick which one when several are connected) or a single window. The app's own windows (panel, countdown, camera bubble) are left out of the recording
- **3-2-1 countdown** before recording starts
- **Global hotkeys** — ⌘⇧R start (also from the editor, for a retake), ⌘⇧. stop. Registered as system hotkeys, so they don't reach the app being recorded
- Click tracking via Accessibility API (CGEventTap)
- Auto-generated zoom keyframes with smooth ease-in/out camera motion
- **Zoom presets** — Subtle, Demo, Punch (+ per-keyframe scale)
- **Timeline editor** — drag zoom blocks or their edges, trim in/out handles; ⌥←/⌥→ nudge the selected zoom (⇧ for 1 s); VoiceOver labels and adjustments
- **Undo / redo** — ⌘Z / ⇧⌘Z for every edit (a whole drag or slider move is one step); ⌘⌫ deletes the selected zoom
- **Recent projects** — the menu bar panel lists your latest recordings with thumbnails; open one to keep editing or re-export, or move it to the Trash
- **Manual zoom** — draw a region on the preview to add a zoom at the playhead
- **WYSIWYG preview** — same compositor as export (zoom, padding, cursor, ripples)
- **Spring camera** — optional overshoot / settle instead of cubic ease
- **Click ripples** and optional cursor spotlight / click-scale
- **1080p / 720p export** at high quality (~10 Mbps at 1080p60) for editing; size-cap the final assembly
- **Runlyx-style background frame** — dark gradient, rounded corners, shadow
- **Cursor smoothing** — tracked path, smoothed over time so it settles where the mouse stops and passes exactly through each click, composited on export and preview
- Optional **hypher.app watermark** (moves to a free corner when the camera bubble is in the way)
- Hide menu bar & dock during recording (the menu bar is cropped out of display recordings; the Dock is auto-hidden)
- **Microphone** — optional narration with device picker
- **System audio** — optional; recorded as its own track and mixed with the mic on export
- 5K/6K displays are recorded (and exported at Source size) with HEVC, which H.264 can't encode at that size
- **Camera bubble** — Screen Studio–style circular PiP (mirrored). Recorded as its own track and composited at render time, so it isn't zoomed with the screen, keeps moving while the screen is still, and can be hidden, resized, or moved to another corner in the editor
- Offline export to MP4 with zoom applied, rendered at a constant frame rate so zooms, cursor, and ripples stay smooth even when the screen is still (the capture itself only gets frames when something changes)
- Project bundles saved to `~/Movies/Recorder/<uuid>.recorder/`

See [DEMO.md](DEMO.md) for the Hypher launch video rehearsal script.

## Requirements

- macOS 13.0+
- Xcode 16+
- Permissions:
  - **Screen Recording** — capture display
  - **Accessibility** — track mouse clicks for auto zoom
  - **Camera** — optional talking-head bubble
  - **Microphone** — optional narration
  - **Automation (System Events)** — only for "Hide menu bar & dock"; asked once, before the countdown

## Build & Run

```bash
open Recorder.xcodeproj
```

Select the **Recorder** scheme and run (⌘R). The app appears in the menu bar.

Or from the command line:

```bash
xcodebuild -project Recorder.xcodeproj -scheme Recorder -configuration Debug build
```

### Signing (so permissions stick between builds)

macOS remembers Screen Recording, Accessibility, Camera, and Microphone access per code
signature. Out of the box the app is signed ad hoc ("Sign to Run Locally"), which produces a
different signature on every build, so macOS asks for those permissions again after each
rebuild. Sign with your Apple Development certificate once and they persist:

```bash
scripts/configure-signing.sh             # uses the team of the Apple Development certificate in your keychain
scripts/configure-signing.sh ABCDE12345  # or pass your Team ID
```

This writes `Config/Local.xcconfig` (git-ignored, see `Config/Local.xcconfig.example`);
signing settings live in `Config/Signing.xcconfig`. Then, one time only: remove the old
"Recorder" rows under **System Settings → Privacy & Security → Screen Recording** and
**Accessibility**, build and run, and grant them again.

- The bundle identifier is `app.hypher.recorder`. To use your own, add
  `PRODUCT_BUNDLE_IDENTIFIER = com.example.recorder` to `Config/Local.xcconfig`.
- Check which identity a build used:
  `codesign -dv --verbose=2 path/to/Recorder.app 2>&1 | grep -E "Authority|TeamIdentifier"`
- Sharing builds with other Macs needs a Developer ID certificate and notarization: see [Distribution](#distribution).


### Distribution

`scripts/release.sh` builds Release signed with your **Developer ID Application**
certificate (hardened runtime, secure timestamp), notarizes it, staples the ticket, and
leaves `build/release/Recorder.zip`. One-time setup: create the certificate (Xcode >
Settings > Accounts > Manage Certificates) and store notarization credentials:

```sh
xcrun notarytool store-credentials recorder-notary --apple-id you@example.com --team-id ABCDE12345
scripts/release.sh            # team from Config/Local.xcconfig, or pass it: scripts/release.sh ABCDE12345
```

## Usage

1. Open the menu bar app and grant Screen Recording + Accessibility permissions.
2. Optionally enable **Microphone** / **Camera** and pick devices.
3. Click **Record** — perform actions on screen (clicks drive auto zoom).
4. Click **Stop** — the editor window opens automatically.
5. Drag zoom blocks on the timeline to adjust timing, or click **Add Manual Zoom** and draw a region on the preview.
6. Toggle spring camera, click ripples, and cursor FX — the preview matches export.
7. Click **Export MP4** when ready, then preview or reveal in Finder.
8. Reopen any earlier take from **Recent** in the menu bar panel (right-click or ⋯ for Show in Finder / Move to Trash).

## Project bundle

Each recording saves:

| File | Description |
|------|-------------|
| `video.mov` | Raw screen capture |
| `events.json` | Click event log |
| `keyframes.json` | Generated zoom keyframes |
| `meta.json` | Capture metadata (size, fps, duration) |
| `cursor.json` | Cursor path (for the smoothed cursor) |
| `camera.mov` | Camera track, aligned to `video.mov` (only when the camera was on) |
| `settings.json` | Editor settings (trim, presets, style) |
| `export.mp4` | Final video with zoom applied |

## Tests

Zoom engine unit tests (Swift Testing):

```bash
swift test
```

CI (`.github/workflows/ci.yml`) runs these tests and builds the app on a macOS runner for every push.

## Architecture

```
Capture (ScreenCaptureKit + CGEventTap)
  → AutoZoomGenerator (clicks → keyframes)
  → CompositionRenderer (preview + export)
  → MP4 export
```

## Deferred

Vertical export, in-app multi-scene stitching (composition model is in place).
