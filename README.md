# Recorder

Native macOS screen recorder with **automatic zoom on clicks** — built for Screen Studio–style Hypher launch demos.

## Features

- Menu bar app — record full display or a single window
- **3-2-1 countdown** before recording starts
- **Global hotkeys** — ⌘⇧R start, ⌘⇧. stop
- Click tracking via Accessibility API (CGEventTap)
- Auto-generated zoom keyframes with smooth ease-in/out camera motion
- **Zoom presets** — Subtle, Demo, Punch (+ per-keyframe scale)
- **Timeline editor** — drag zoom blocks, trim in/out handles
- **Manual zoom** — draw a region on the preview to add a zoom at the playhead
- **1080p / 720p export** with bitrate targeting (~8MB at 60–90s)
- **Runlyx-style background frame** — dark gradient, rounded corners, shadow
- **Cursor smoothing** — tracked path composited on export
- Optional **hypher.app watermark**
- Hide menu bar & dock during recording
- **Microphone** — optional narration with device picker
- **Camera bubble** — Screen Studio–style circular PiP (mirrored, corner position)
- Offline export to MP4 with zoom applied
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

## Build & Run

```bash
open Recorder.xcodeproj
```

Select the **Recorder** scheme and run (⌘R). The app appears in the menu bar.

Or from the command line:

```bash
xcodebuild -project Recorder.xcodeproj -scheme Recorder -configuration Debug build
```

## Usage

1. Open the menu bar app and grant Screen Recording + Accessibility permissions.
2. Optionally enable **Microphone** / **Camera** and pick devices.
3. Click **Record** — perform actions on screen (clicks drive auto zoom).
4. Click **Stop** — the editor window opens automatically.
5. Drag zoom blocks on the timeline to adjust timing, or click **Add Manual Zoom** and draw a region on the preview.
6. Click **Export MP4** when ready, then preview or reveal in Finder.

## Project bundle

Each recording saves:

| File | Description |
|------|-------------|
| `video.mov` | Raw screen capture |
| `events.json` | Click event log |
| `keyframes.json` | Generated zoom keyframes |
| `meta.json` | Capture metadata (size, fps, duration) |
| `export.mp4` | Final video with zoom applied |

## Tests

Zoom engine unit tests (Swift Testing):

```bash
swift test
```

## Architecture

```
Capture (ScreenCaptureKit + CGEventTap)
  → AutoZoomGenerator (clicks → keyframes)
  → ZoomVideoCompositor (per-frame crop/zoom)
  → MP4 export
```

## Deferred

System audio (app/desktop sound), vertical export, in-app multi-scene stitching.
