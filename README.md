# Trace

**Polished product demos, straight from your screen.** Trace is a native macOS menu bar
recorder: pick an area, a window or a display, record, and get a video that already
zooms in on every click, glides the cursor, and sits on a clean background. Then cut,
speed up, annotate and export it in minutes.

> **Status.** Everything here is built and its logic unit-tested in CI (`swift test` plus
> an Xcode build on macOS 15). Capture, preview and export have **not yet been run on a
> real Mac** since the redesign. See the verification checklist in
> [CLAUDE.md](CLAUDE.md#verify-on-a-mac) before relying on it.

## What it does

**Record**
- Record an **area** (drag it, or pick 16:9, 4:3, 1:1, 9:16, 1280×720, 1920×1080), a
  **window**, or a **display**. The last area is remembered, so a retake is ⇧⌘R then ⏎.
- 3-2-1 countdown, a floating **HUD** with timer, **pause/resume**, restart and discard.
- **Clean screen** without touching your settings: notifications and (optionally) desktop
  icons are left out of the capture; full-display takes can hide the menu bar and Dock.
- **Microphone**, **system audio** (its own track) and a **camera bubble** (its own
  track, drag it to any corner while recording).
- **Keystrokes** (optional, needs Input Monitoring) and the cursor's shape (arrow, I-beam,
  pointing hand) are recorded for the overlays.
- **Which app is in front**, and where its window is, so a take can be cropped to your app
  and detours into other apps found. Window titles are never kept.
- 30 or 60 fps; 5K/6K displays export with HEVC.

**After recording**
- A **Quick Access** card with Edit, Export, Copy (paste the video into Slack or Mail) and
  Show in Finder; drag the card's file straight into any app. Or open the editor directly.
- A **Library** of every take: search, sort, rename, open, reveal, move to Trash.

**Edit**
- **Canvas** at the video's final shape (16:9, 9:16, 1:1, 4:3, 4:5 or as recorded), with
  the same renderer as the export, so what you see is what you get.
- **Multi-track timeline**: clips with thumbnails, zooms, text, blur and the audio
  waveform. **Split** (S), **delete** clips, **trim** clip edges, **speed up** any clip
  (0.25–16×, pitch kept) or every idle stretch at once. Drags snap to the playhead and edges.
- **Auto zoom** on every click (Subtle, Demo or Punch), with spring motion and optional
  motion blur. Add zooms by dragging on the preview (Z) or along the zoom track, and aim
  any zoom by dragging its focus frame.
- **Crop** to part of the screen, like your app's window: zooms push in within it and the
  canvas follows its shape.
- **Text** (title, caption, callout) that fades, rises, pops, comes into focus or types
  on; **blur/pixelate** boxes that follow zooms; a **keystroke** overlay for shortcuts or
  typing.
- **Motion**: speed changes that ease in and out, zoom-blur, whip or blur transitions at
  cuts with short audio fades, and **3D moves** (tilt in, tilt out, float, orbit, push in)
  on their own timeline track.
- **Look**: 12 wallpapers, gradients, colours or your own picture; padding, corners and
  shadow; cursor size and idle hiding; click ripples and spotlight; camera shape, size
  and border; watermark. Save looks and choose one for every new recording.
- Undo and redo for everything; a whole drag is one step.

**Export**
- **MP4** (H.264), **HEVC**, **ProRes 422** (MOV, uncompressed audio) or **GIF**; Web,
  High or Studio quality; 24/30/60 fps; 720p to 4K or source size.
- To `~/Movies/Trace/Exports` (or any folder, or ask every time), with name templates,
  never overwriting. Cancel any time; nothing half-written is left behind.
- Copy, Share, Show in Finder, or drag the file out when it's done.

## Agents (MCP)

An AI agent (Claude Code, Claude Desktop, Cursor or any MCP client) can edit your takes:
cut them down, keep only your app on screen, turn them into a motion launch demo and
export it.

1. In Trace, turn on **Settings › Agents › Allow AI agents**. It's off until you do.
2. Connect your agent. The settings pane has copy buttons for both of these:

   ```bash
   claude mcp add --scope user trace -- /Applications/Trace.app/Contents/MacOS/Trace --mcp
   ```

   ```json
   { "mcpServers": { "trace": { "command": "/Applications/Trace.app/Contents/MacOS/Trace", "args": ["--mcp"] } } }
   ```

3. Ask for what you want, or pick the **launch_demo** prompt in your client:
   *"Turn my latest take into a 16:9 launch demo of Acme: cut the dead time and the detour
   to Slack, keep only the Acme window, add a title and captions, then export an MP4."*

| Tool | What it does |
|------|--------------|
| `list_takes`, `get_take` | The library, and everything about one take's edit |
| `analyze_take` | Finds the lead-in, tail, dead air, waits and detours into other apps, and suggests cuts. Speech is never cut |
| `view_frames` | Frames as images: the raw recording (with a coordinate grid) or rendered exactly as it will export |
| `make_launch_demo` | The whole pass in one step: trim, cut, speed through waits, crop to the app, zooms, a 3D tilt-in, transitions, title and captions |
| `edit_timeline`, `set_crop`, `edit_zooms`, `edit_text`, `edit_blur`, `edit_camera_moves`, `set_style` | Precise edits |
| `undo` | Takes back the agent's last edit |
| `export_video`, `export_status` | MP4, HEVC, ProRes or GIF |
| `open_take` | Shows the take in the editor |

- **Every agent edit is one undo step**, named "Agent: …". An open take changes live in
  the editor, where ⌘Z undoes it. A take that isn't open is saved quietly, and the `undo`
  tool reverts it.
- **Agents edit; they don't record.** Rendering, analysis and export wait while you're
  recording.
- **Only you can connect.** Agents reach Trace through a socket in
  `~/Library/Application Support/Trace/Agent/` that only your user account can open, and
  only while the setting is on. When it's off, the agent is told how to turn it on, and
  Trace isn't launched. When Trace isn't running, the first call opens it in the
  background.
- `Trace --mcp` is the app's own binary, started in a helper mode. There's nothing else
  to install or sign.

## Keyboard

Global (Settings › Shortcuts to change them):

| Keys | Action |
|------|--------|
| ⇧⌘R | Record (opens the selector with your last choice) |
| ⇧⌘. | Stop |
| ⇧⌘, | Pause or resume (while recording) |

In the selector: ⏎ records, Space switches Area/Window, arrows nudge the area (⇧ for 10 px), Esc cancels.

In the editor:

| Keys | Action |
|------|--------|
| Space | Play or pause |
| ← → | Previous or next frame (⇧ for a second) |
| ⌘← ⌘→ | Start or end |
| S or ⌘B | Split at the playhead |
| ⌫ | Delete the selection |
| Z | Add a zoom (drag over the preview) |
| T / B | Add text / a blur box at the playhead |
| ⌥← ⌥→ | Nudge the selection (⇧ for a second) |
| ⌘+ ⌘− ⌘0 | Zoom the timeline, fit it |
| ⌘Z ⇧⌘Z | Undo, redo |
| ⌘E | Export |
| Esc | Clear the selection, leave a mode |

## Requirements

- macOS 14 or later; Xcode 16 to build.
- Permissions (the onboarding window walks through them):
  - **Screen Recording** (required)
  - **Accessibility**, to follow clicks for auto zoom (required)
  - **Microphone**, **Camera**, **Input Monitoring** (for keystrokes), optional
  - **Automation (System Events)**, only for hiding the Dock

## Build and run

```bash
open Recorder.xcodeproj    # run the Recorder scheme (⌘R); Trace appears in the menu bar
xcodebuild -project Recorder.xcodeproj -scheme Recorder -configuration Debug build
```

The target, module and bundle ID (`app.hypher.recorder`) keep their original names so
permissions and existing projects carry over; the app itself is called Trace.

### Signing (so permissions stick between builds)

macOS remembers Screen Recording, Accessibility, Camera and Microphone access per code
signature. Ad hoc builds get a new signature every time, so macOS asks again after each
rebuild. Sign with your Apple Development certificate once:

```bash
scripts/configure-signing.sh             # the team of the Apple Development certificate in your keychain
scripts/configure-signing.sh ABCDE12345  # or pass your Team ID
```

This writes the git-ignored `Config/Local.xcconfig`; shared settings are in
`Config/Signing.xcconfig`. After switching, remove the old rows under System Settings ›
Privacy & Security › Screen Recording and Accessibility, run, and grant them again. To use
your own bundle ID, add `PRODUCT_BUNDLE_IDENTIFIER = com.example.trace` to `Local.xcconfig`.

### Distribution

`scripts/release.sh` builds Release with your **Developer ID Application** certificate
(hardened runtime, secure timestamp), notarizes, staples, and leaves
`build/release/Trace.zip`:

```sh
xcrun notarytool store-credentials recorder-notary --apple-id you@example.com --team-id ABCDE12345
scripts/release.sh
```

## Where things live

| Path | What |
|------|------|
| `~/Movies/Trace/<uuid>.recorder/` | One bundle per recording (older builds' `~/Movies/Recorder` is moved here on first launch) |
| `~/Movies/Trace/Exports/` | Default export folder |
| `~/Library/Application Support/Trace/styles.json` | Saved looks and the default for new recordings |
| `~/Library/Application Support/Trace/Agent/` | The socket agents connect through, while Allow AI agents is on |

Inside a bundle:

| File | What |
|------|------|
| `video.mov` | The screen capture (mic and system audio as separate tracks) |
| `camera.mov` | Camera track, aligned to the video (when the camera was on) |
| `meta.json` | Size, fps, duration, capture target, name, pause points |
| `events.json`, `cursor.json` | Clicks and the cursor path |
| `inputs.json` | Key presses, cursor shapes, and which app was in front and where its window was |
| `keyframes.json` | Zooms |
| `settings.json` | The edit and the look (versioned; newer files are never overwritten by older builds) |
| `exports.json` | Where the latest export went |
| `background-*.png` | A picture used as the background |

## Tests

```bash
swift test
```

The `RecorderCore` package holds everything that doesn't need a screen: the edit timeline
and time mapping, pause handling, canvas and overlay layout, area selection, zoom
generation and focus, hotkeys and editor shortcuts, keystroke labels and pills, looks and
presets, export options and naming, GIF timing, project storage and migrations, crop,
text motion, speed ramps, transitions and 3D moves, and the agent side: the MCP
protocol, the socket bridge, agents' edits, take analysis and the launch-demo recipe. CI
(`.github/workflows/ci.yml`) runs the tests, builds the app and checks `Trace --mcp`
with `scripts/mcp-smoke.py` on every push.

## How it fits together

```
ScreenCaptureKit + CGEventTap ──► project bundle (source time)
                                        │
            EditTimeline (cuts, speed) ─┤  source time ⇄ output time
                                        ▼
      CompositionRenderer ── preview (AVPlayer + display link)
                          └─ export (fixed-rate clock) ──► MP4 / HEVC / ProRes / GIF
```

Everything recorded (clicks, cursor, keys, zooms, text, blur, camera) is in **source
time**, the recording's own clock. The edit maps **output time** (what you watch) back to
it, so cutting or speeding up never moves an overlay off the moment it belongs to.

Agents reach the same edit through the running app:

```
Claude / Cursor ──stdio──► Trace --mcp ──Unix socket──► Trace.app: AgentToolHost
                           (MCP, tool list)              open take → the editor (one undo step)
                                                         closed take → the project bundle
```

See [DEMO.md](DEMO.md) for a step-by-step guide to recording a product demo.
