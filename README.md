# stage-studio

A tiny macOS CLI that records a window and outputs a polished MP4 — single window, isolated from notifications and other apps, composited onto a vibrant background with rounded corners and a soft drop shadow. Built to be driven from a Claude Code chat as much as from the terminal.

Replaces Screen Studio ($89/yr) and OBS (heavy) for one specific need: "I want a clean shareable clip of this thing on my screen, right now, without opening any software."

**Mac-only.** Tested on Apple Silicon, macOS 15+.

---

## What it does

```bash
# in any Claude Code session, with the stage-studio skill loaded:
you:    let's record a clip of this Linear ticket
claude: [identifies your Linear window, starts recording]
        "Recording. Say stop when done."
you:    [demo your thing, then come back to claude]
        stop
claude: "Done. out/linear-dig228-20260516-105132.mp4"
```

Output:

- 1920×1080 H.264 MP4 with mic audio
- Only your target window — overlapping windows, notifications, the dock, the menubar all stay out
- The window has its native rounded corners, with a soft drop shadow and the Big Sur Color Day wallpaper as the background

Or use it as a plain CLI without Claude — see below.

---

## Quick install

You need:

- macOS 15 or later (Sequoia / Tahoe)
- Xcode Command Line Tools: `xcode-select --install`
- [Bun](https://bun.sh): `curl -fsSL https://bun.sh/install | bash`
- ffmpeg (optional, only for debugging frame extraction): `brew install ffmpeg`

Then:

```bash
git clone https://github.com/<owner>/stage-studio.git
cd stage-studio
bun install
pnpm run build      # compiles the three Swift binaries
```

That's it. The binaries land in `cmd/clicks/clicks`, `cmd/windows/windows`, `cmd/recorder/recorder`.

---

## One-time permission setup

macOS requires four TCC permissions for stage-studio to work. **Grant them all to the terminal app you'll run stage-studio from** (Terminal, iTerm, cmux, etc.). Open *System Settings → Privacy & Security* and toggle each:

| Permission | Why | Symptom if missing |
|---|---|---|
| **Screen Recording** | ScreenCaptureKit needs this to capture window pixels | Recordings come out blank / black, no error |
| **Microphone** | AVCaptureSession needs this for audio | Video has no audio track |
| **Accessibility** | `CGEvent.tapCreate` for cursor tracking | Cursor positions not captured (currently unused in output, but recorded for future overlays) |
| **Input Monitoring** | Needed for mouse-button events to reach the event tap | Move events captured but click events silently dropped |

**Important:** after enabling **Input Monitoring**, you must restart the terminal app — that grant doesn't take effect until the parent process restarts.

---

## Three ways to use it

### 1. From a Claude Code chat (the intended UX)

The repo ships with a Claude skill at `.claude/skills/stage-studio/SKILL.md`. Open the repo (or any project that has stage-studio installed) in Claude Code, and ask Claude to record something:

> *"Let me record a clip of what we just built."*

Claude will:

1. Enumerate your open windows
2. Pick the relevant one contextually, or ask which one if it's ambiguous
3. Spawn the recorder in a background bash task with open-ended duration
4. Tell you "recording — say stop when done"
5. When you say stop, SIGTERM the recorder so it finalizes the MP4 cleanly
6. Tell you where the output landed

This is the path everything is optimized for. You stay in chat the whole time.

### 2. From the terminal directly

```bash
# fixed-duration recording targeting the frontmost non-terminal window
bun run cli --duration 8 --output ./demo.mp4

# fixed duration, targeting a window by title substring
bun run cli --duration 10 --window "Linear" --output ./demo.mp4

# open-ended recording — runs until you SIGTERM the recorder PID
bun run cli --duration 0 --window-id 8387 --output ./demo.mp4
# prints "[stage-studio] recorder PID: 12345" to stdout
# in another shell: kill -TERM 12345  (recorder finalizes, MP4 saved)
```

Listen for the **Tink** sound — that's recording start. **Pop** is recording stop.

### 3. The hotkey app (no Claude session needed)

The capture pipeline is solid, but starting a recording used to require a Claude
session — so it didn't get reached for. `app/` is a standalone native front door
onto the *same* recorder. The Claude and CLI flows are untouched.

```bash
pnpm run build:app
open app/build/StageStudio.app     # or run the binary inside for logs on stdout
```

It's an agent app (`LSUIElement`) — no Dock icon, no window until you summon one.
There's a small menu-bar item, but that's a quit escape hatch, not the interface.

**The flow:**

| Step | What you see |
|------|--------------|
| `⌥⌘R` | Centered picker panel — live thumbnails of every on-screen window |
| `←→↑↓` / mouse | Move the selection |
| `↩` or click | Pick it |
| — | A pill appears bottom-center and counts down **3 · 2 · 1**, naming the app |
| — | Same pill flips to recording: red dot, elapsed time, **Stop** |
| Stop / `esc` / `⌥⌘R` | Recorder finalizes, pill flashes `Saved ✓ <file> · <duration>`, fades |
| Click the filename | Reveals the recording in Finder, selected and ready to drag |

Output lands at `~/Desktop/recording-<timestamp>.mp4`.

The saved pill fades after ~4s, but **hovering it stops the clock** — including
catching a fade that has already started — so the click target can't disappear
while you're reaching for it. Moving off restarts the timer.

`esc` cancels at any point. Cancelling the countdown writes nothing at all;
cancelling a recording stops the recorder and deletes the partial file.

**On `esc`:** it's a global hotkey, so it's grabbed from every other app while
it's registered — which is why it's registered *only* for the seconds a pill is
on screen and released in every exit path. Outside a session, `esc` is yours.

Both hotkeys use Carbon's `RegisterEventHotKey`, which needs **no Accessibility
permission** — the app adds no permission types beyond the Screen Recording and
Microphone grants the recorder already needs.

**Verifying a surface without recording anything:**

```bash
APP=app/build/StageStudio.app/Contents/MacOS/StageStudio

# summon a surface, screenshot it, quit — self-cleaning
$APP --debug-show picker --debug-capture /tmp/picker.png
$APP --debug-show pill-recording --debug-capture /tmp/pill.png
$APP --debug-show pill-countdown --debug-midline   # midline = centering check
$APP --debug-show pill-saved --debug-hover         # filename's click affordance
$APP --debug-reveal                                # exercise the Finder reveal

# drive the whole session against one window, then quit
$APP --debug-record "Safari" --debug-record-seconds 5
```

`app/tools/inkbox` measures where text ink actually sits relative to a row's
midline in a screenshot, so "optically centered" stays a number rather than an
impression.

#### CLI reference

```
  -t, --duration <s>    seconds, or 0 for open-ended (stops on SIGTERM, 5min cap)
  -o, --output <path>   final MP4 path (default ./out.mp4)
  -w, --window <pat>    target window pattern (case-insensitive substring)
      --window-id <N>   target specific CGWindowID (use `cmd/windows list` to find)
      --work-dir <p>    intermediate artifacts (default ./out)
      --skip-record     reuse the last recording, re-render only
```

#### Picking a window manually

```bash
./cmd/windows/windows list           # all on-screen windows as JSON
./cmd/windows/windows frontmost      # frontmost non-terminal window
./cmd/windows/windows find Slack     # fuzzy match on app/title
```

---

## Changing the background

Default is the Big Sur Color Day wallpaper shipped in `assets/big-sur-graphic.jpg`. Override with any JPEG/PNG/HEIC:

```bash
RECORDER_BG_IMAGE=/path/to/your-wallpaper.png bun run cli ...
```

The image is scale-to-filled and center-cropped to 1920×1080. Square wallpapers (like Apple's 6016×6016 originals) work great.

If you want a procedural background instead of an image, set `RECORDER_BG_IMAGE=""` and the recorder falls back to a SwiftUI `MeshGradient` with a warm peach→mocha palette.

---

## How it works

```
┌──────────────────┐
│ cmd/windows      │ ── window id ──┐
│ (CGWindowList)   │                │
└──────────────────┘                ▼
                          ┌──────────────────┐
┌──────────────────┐      │ src/cli.ts (Bun) │
│ cmd/clicks       ├JSONL▶│ - detect window  │
│ (CGEventTap)     │      │ - spawn recorder │
└──────────────────┘      │ - mux clicks log │
                          └────────┬─────────┘
                                   │ windowID, durationS, outputPath
                                   ▼
                          ┌──────────────────────────────┐
                          │ cmd/recorder (Swift)         │
                          │                              │
                          │ ScreenCaptureKit             │
                          │   SCContentFilter(window:)   │
                          │   → BGRA with alpha          │
                          │      ↓                       │
                          │ AVCaptureSession mic         │
                          │      ↓                       │
                          │ Core Image (Metal)           │
                          │   background image           │
                          │   + alpha-shaped drop shadow │
                          │   + aspect-fit window        │
                          │      ↓                       │
                          │ AVAssetWriter H.264 + AAC    │
                          └────────────┬─────────────────┘
                                       ▼
                                   output.mp4
```

**One process, hardware-accelerated end to end.** ScreenCaptureKit captures the target window's actual rendered content — not what's on screen. Notifications, occluding windows, the dock, the menubar: none of them appear in the output. Core Image composites each captured frame onto the styled background using the window's native alpha as the shape (so corners curve correctly regardless of the app). AVAssetWriter encodes the composite directly with muxed mic audio. No Remotion, no Chromium, no intermediate files.

---

## Architecture history

This repo contains the trajectory of a few earlier attempts, kept as reference:

- **`render/`** — original Remotion-based compositor. Worked for the initial zoom-on-click feature but couldn't preserve HEVC-with-alpha source video through its pipeline. Replaced by the Swift-side Core Image compositor in `cmd/recorder/`.
- **`test/`** — synthetic pixel-sampling validation harness built for the abandoned zoom-on-click feature. Calibration grid + center-pixel color assertions. Pattern still useful if a similar visual feature comes back.
- **`SHAPE-ui.md`** — design doc on why "Claude as the UI" beat building a SwiftUI app. Saved hours of work.

---

## Known limits

- **Browser windows include browser chrome.** Cropping a Chrome window gets the address bar and tabs too. Future: app-specific chrome stripping.
- **5-minute hard cap on open-ended recordings.** A safety to prevent forgotten recordings from filling the disk. Bump via `OPEN_ENDED_MAX_DURATION_S` in `cmd/recorder/main.swift` if you need longer.
- **A/V sync drifts over long recordings.** Fine for ≤30s clips. ScreenCaptureKit and AVCaptureSession share the mach clock so it's a slow drift, not a sudden one.
- **No pause.** Stop and re-record covers the same need with less mechanism.
- **X / hard kill on the recorder loses the recording.** SIGKILL doesn't give AVAssetWriter time to finalize the MP4. Stop via "say stop to Claude" or `kill -TERM <recorder-pid>`, which traps cleanly. Documented gap.
- **Mac-only, single display, no webcam, no system audio (mic only).**
- **The hotkey app is unsigned and locates the recorder by relative path.** It
  expects to live at `<repo>/app/build/StageStudio.app`; set `STAGE_STUDIO_ROOT`
  if you move it. No signing/notarization — single-user local phase.
- **The hotkey app's hotkey is hardcoded to `⌥⌘R`.** No settings UI; if another
  app already owns that combination, registration fails and it says so on stderr.

---

## Repo layout

```
stage-studio/
├── .claude/skills/stage-studio/  Claude skill for the chat-driven flow
├── app/                       Hotkey recorder — LSUIElement agent app (Swift)
│   ├── Sources/               main, AppDelegate, picker, pill, session, hotkeys
│   ├── Resources/Info.plist   LSUIElement, mic usage string
│   ├── tools/inkbox/          Measures text ink vs. a row midline in a shot
│   └── build.sh               → build/StageStudio.app (unsigned, ad-hoc signed)
├── assets/                    Default background image
├── cmd/
│   ├── clicks/                CGEventTap mouse capture (Swift)
│   ├── windows/               CGWindowListCopyWindowInfo enumeration (Swift)
│   ├── recorder/              SCK + Core Image + AVAssetWriter pipeline (Swift)
│   └── gradient-preview/      Standalone renderer for background variants (Swift)
├── render/                    v1 Remotion compositor (backlogged)
├── src/
│   └── cli.ts                 Bun orchestrator
├── test/                      v1 pixel-sampling validation harness
├── SHAPE-ui.md                Design rationale for Claude-as-UI
└── README.md                  this file
```

---

## License

MIT.
