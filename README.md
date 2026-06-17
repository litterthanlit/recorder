# Recorder

Native macOS screen recorder with **automatic zoom on clicks** — a Screen Studio–style MVP built with Swift, ScreenCaptureKit, and AVFoundation.

## Features (v1)

- Menu bar app — record primary display with cursor visible
- Click tracking via Accessibility API (CGEventTap)
- Auto-generated zoom keyframes with smooth ease-in/out camera motion
- Offline export to MP4 with zoom applied
- Project bundles saved to `~/Movies/Recorder/<uuid>.recorder/`

## Requirements

- macOS 13.0+
- Xcode 16+
- Permissions:
  - **Screen Recording** — capture display
  - **Accessibility** — track mouse clicks for auto zoom

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
2. Click **Record** — perform actions on screen (clicks drive auto zoom).
3. Click **Stop** — the app generates zoom keyframes and exports `export.mp4`.
4. Preview the result in the popover, or click **Show in Finder**.

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

## Deferred (v2+)

Manual zoom, timeline editor, vertical export, cursor smoothing, backgrounds, audio/webcam.
