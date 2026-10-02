# Recording a product demo with Trace

A practical guide for a 30–90 second launch or feature video. Most demos come together
in a single afternoon: three or four short takes, one editing pass each, then export.

## Before you record

- [ ] **Plan the story in beats**: problem → the one action that solves it → the result.
      One beat per take; short takes are easier to redo than long ones.
- [ ] **Prepare the product**: demo data loaded, logged in, nothing personal on screen.
      Use a clean browser profile with no bookmarks bar or extensions you don't need.
- [ ] **Set the window size** to the shape you'll publish: 1280×720 or 1920×1080 for
      web and YouTube, a narrower window for vertical social clips.
- [ ] **Turn on Do Not Disturb.** Trace leaves notification banners out of display and
      area recordings anyway, but sounds can still reach the microphone.
- [ ] **In Settings**: countdown 3 s, 60 fps, "Show keystrokes" on if shortcuts matter.
- [ ] **Pick a default look** (Background › Look › "New takes"), so every take starts
      styled the same way.

## Choosing what to record

| Capture | Use it when |
|---------|-------------|
| **Area** | Almost always. Drag the part that matters, or choose 16:9 / 1:1 / 9:16. The area is remembered, so the next take is ⇧⌘R then ⏎. |
| **Window** | One app window, following it if it moves. Keep other windows from covering it. |
| **Display** | Showing several apps or the desktop. Hide the menu bar and Dock in Settings. |

## Each take

1. Put the cursor where the take should start, then **⇧⌘R** and **⏎**.
2. Wait for 3-2-1. Move deliberately: pause a beat before each click, since auto zoom
   centres on it and the viewer needs a moment to see what changed.
3. Made a mistake? **⇧⌘,** pauses; the HUD's restart button throws the take away and
   starts again.
4. **⇧⌘.** stops. The Quick Access card appears: **Edit** to polish.

## The editing pass

Work top to bottom; the whole pass takes a few minutes per take.

1. **Shape.** Pick the video's shape in the toolbar (16:9 for web, 9:16 for Reels and
   Shorts, 1:1 for feeds).
2. **Cut dead air.** Press S at the start and end of a pause, select the clip between,
   press ⌫. Trim the first and last clips by dragging their edges.
3. **Tighten the pace.** Select a slow clip and give it 2× in the inspector, or use
   **Speed Up Idle** to play every stretch without clicks or typing at 4×.
4. **Check the zooms.** Auto zoom follows your clicks. Delete the ones that distract
   (select, ⌫), drag their edges to hold longer, and use **Adjust Focus** to aim one at
   exactly the right spot. Press Z and drag over the preview to add your own.
5. **Say what's happening.** Press T for a caption at the playhead; drag it into place
   on the preview. Use Title for an opening line, Callout to point at a feature.
6. **Hide anything private.** Press B for a blur box and drag it over emails, names or
   keys. It follows zooms; drag its ends on the Blur track to cover the whole stretch.
7. **Polish the look.** Background, padding and corners; cursor size (1.5× reads well on
   small screens); click ripples on for tutorials, off for cinematic cuts.
8. **Save the look** once you like it, and make it the default for new takes.

## Let an agent edit it

An AI agent can do the editing pass for you. Turn on **Settings › Agents › Allow AI
agents**, connect Claude Code, Claude Desktop or Cursor (the [README](README.md#agents-mcp)
shows how), and describe the video you want:

> Make my latest take into a 16:9 launch demo of Acme. Cut the setup and the part where I
> switched to Slack, keep only the Acme window, title it "Acme 2.0", add a short caption
> for each step, then export an MP4.

The agent reads the take: clicks, typing, speech, how much the screen changes and which
app was in front. It looks at frames to write the captions, then makes the whole pass in
one step:

1. It trims the setup and the stop.
2. It cuts pauses and detours into other apps. Speech is never cut.
3. It speeds through waits like page loads, easing in and out of them.
4. It crops to your app's window and follows it if you move it. Notifications and other
   apps' windows over it are blurred, or cut when they hide much of it.
5. It zooms onto your clicks.
6. It opens with a 3D tilt-in and adds transitions at the cuts.
7. It brings the title and captions on in motion.

Last, it checks rendered frames, fixes what's off and exports.

- **Keep the take open in the editor** to watch the edits land. Each agent step is one
  undo step ("Agent: Launch Demo"), so ⌘Z takes it back.
- **Record as usual.** Takes from this version on remember which app was in front, where
  its window was and what lay over it, so cropping, cutting detours and hiding other apps
  need no guessing. For older takes, the agent reads the window's position off the frames
  instead. Window recordings show only the window, so nothing else can get in.
- **Say how tight**: "relaxed" keeps more breathing room, "punchy" cuts every pause. Name
  a look ("Vivid", "Midnight"), or ask for 9:16 for Reels and Shorts.
- **Still check it yourself.** The agent can't know what's private to you. Look for names,
  emails and keys, and ask it to blur them (or press B). Pauses in narration may be
  tightened, so listen once.

### Direct it as a storyboard

For a more produced video, ask the agent to direct it (or pick the **storyboard_demo**
prompt). It watches the take, then writes a storyboard: a handful of shots in the order you
recorded them, each with a camera move and a few words of kinetic type.

- **A hook in the first 2 s**: a short opening shot on a striking moment, with a title
  and a push in.
- **A payoff every 3–5 s**: a result appearing, a caption landing, a zoom arriving.
- **The camera** zooms in, pushes slowly closer, pulls back to reveal, or pans from one
  part of the screen to another; a still screen can float or orbit in 3D.

Then it critiques the result: Trace renders stills where it matters and scores each one
(readable text, text clear of what you clicked, the action in frame, not zoomed past
sharp, something changing, no other app showing). It fixes the three worst, scores again,
and the agent fixes what needs taste. Last, it exports 16:9, 9:16 and 1:1 from the same
edit. The tall and square versions are reframed: a frame of that shape follows your clicks
and typing, and text moves clear of the controls Reels, TikTok and Shorts put over the
video.

Shots play in recording order: Trace never jumps back. If the best moment is at the end,
it's the payoff, not the opening.

## Export

| Destination | Format | Quality | Notes |
|-------------|--------|---------|-------|
| Landing page, docs video | MP4 | Web | Small and plays everywhere |
| YouTube, Product Hunt | MP4 | High | 1080p, 60 fps |
| Social (Reels, TikTok, Shorts) | MP4 | High | 9:16 shape, 1080p |
| README, Slack, Notion | GIF | n/a | Under 30 s, 15 fps, scaled to 720 px wide |
| Further editing (Final Cut, Premiere) | ProRes | n/a | Large files, best quality |

**⌘E** opens the export sheet. When it's done, **Copy** puts the file on the clipboard
ready to paste, or drag the file icon straight into Slack, Mail or your editor.

## Putting takes together

Trace exports each take on its own. For a multi-scene video, export every take as MP4
High (or ProRes), assemble them in your video editor, add music and short cross-dissolves
(0.2–0.3 s), and do the final size-limited export there.

## Checklist before publishing

- [ ] Nothing private visible (blurred, or not on screen at all)
- [ ] No Trace UI in the shot (the HUD, countdown and camera controls are never recorded)
- [ ] Every zoom helps the viewer; none jump for a stray click
- [ ] Captions are short and on screen long enough to read (about 3 s for five words)
- [ ] Audio levels balanced between narration and system sound
- [ ] Watched once with sound off, once at full screen
