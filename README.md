# stage-studio

A tiny macOS CLI that records a window and outputs a polished MP4 — single window, isolated from notifications and other apps, composited onto a vibrant background with rounded corners and a soft drop shadow. Built to be driven from a Claude Code chat as much as from the terminal.

Replaces Screen Studio ($89/yr) and OBS (heavy) for one specific need: "I want a clean shareable clip of this thing on my screen, right now, without opening any software."

**Mac-only.** Tested on Apple Silicon, macOS 15+.

---

## What it does

```bash
# in any Claude Code session, with the stage-studio skill loaded:
you:    let's record a clip of this Linear ticket
claude: [identifies your Linear window, asks the app to record it]
        [a pill appears bottom-center: "Claude · Recording Linear…" 3 · 2 · 1]
        "Recording. Say stop when done."
you:    [demo your thing, then come back to claude]
        stop
claude: "Done. out/linear-dig228-20260516-105132.mp4"
```

The pill is not decoration. Any recording — yours or Claude's — is visible while it
happens and dies on `esc`. That's the precondition for letting an agent start one.

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

Recording routes through `/Applications/Stage Studio.app`, so **the permissions live on the app**, granted once. Launch it, record something, and macOS asks for Screen Recording and Microphone the first time. Because the bundle id is frozen and the app is signed with a real Developer ID, those grants survive every rebuild — see [the hotkey app](#3-the-hotkey-app-no-claude-session-needed).

| Permission | Granted to | Why | Symptom if missing |
|---|---|---|---|
| **Screen Recording** | Stage Studio.app | ScreenCaptureKit needs this to capture window pixels | Recordings come out blank / black, no error |
| **Microphone** | Stage Studio.app | AVCaptureSession needs this for audio | Video has no audio track |

That's the whole list for the normal path. The hotkeys use Carbon's `RegisterEventHotKey` and the control surface is a Unix socket, so neither adds an Accessibility, Input Monitoring, Automation, or firewall prompt.

**`--headless` is the exception.** It bypasses the app and spawns the recorder inside your shell, so the grants it needs are the ones on *your terminal app* (Terminal, iTerm, cmux…) — Screen Recording and Microphone as above, plus **Accessibility** and **Input Monitoring** for the click/cursor track. Input Monitoring doesn't take effect until you restart the terminal. Consolidating onto the app is precisely what makes this table shorter for everyone else.

---

## One engine, three front doors

There is only one recording engine now: the app. The hotkey, the CLI and Claude are three ways to ask it for a recording, and **every one of them puts the pill on screen**. A recording you can't see and can't kill isn't something this tool knows how to make.

### 1. From a Claude Code chat (the intended UX)

The repo ships with a Claude skill at `.claude/skills/stage-studio/SKILL.md`. Open the repo (or any project that has stage-studio installed) in Claude Code, and ask Claude to record something:

> *"Let me record a clip of what we just built."*

Claude will:

1. Enumerate your open windows
2. Pick the relevant one contextually, or ask which one if it's ambiguous
3. Ask the app to start recording — launching it first if it isn't running
4. Tell you "recording — say stop when done", once the app confirms capture actually began
5. When you say stop, run `stage-studio stop`; the app finalizes the MP4
6. Tell you where the output landed

What you see: the pill, ringed in violet and credited **"Claude · Recording Safari…"** through the countdown, then **"Claude · 0:07"** while it captures. A human-started session has neither the ring nor the credit — that difference is the whole reason an agent is allowed to start one at all. The record dot stays red either way: red means "capturing right now", whoever asked.

`esc`, the pill's **Stop**, and `⌥⌘R` end Claude's session exactly as they end yours, and Claude is told plainly that you did it rather than being handed a missing file.

### 2. From the terminal directly

The CLI drives the same app, so a terminal recording gets the same pill and the same physical controls.

```bash
# fixed-duration recording of the frontmost non-terminal window
bun run cli --duration 8 --output ./demo.mp4

# fixed duration, targeting a window by title substring
bun run cli --duration 10 --window "Linear" --output ./demo.mp4

# open-ended: returns as soon as capture is underway, then stop when you like
bun run cli --duration 0 --window-id 8387 --output ./demo.mp4
bun run cli stop
```

`start` never answers optimistically — it holds until the countdown has run out, so you learn `recording` or `cancelled`, not a "started" you vetoed a second later. Exit codes say which: **3** busy (a session is already live — it will never queue or preempt), **4** cancelled by hand, **2** the app isn't running, **1** everything else.

```bash
bun run cli status          # what the app is doing, as JSON
bun run cli cancel          # abort and delete the partial file
bun run cli list-windows    # on-screen windows as JSON
bun run cli --headless ...  # bypass the app entirely (see below)
```

**`--headless`** spawns the recorder directly in your shell — the pre-app path. No pill, no countdown, nobody watching. It exists for contexts with no GUI session to show a pill in, and it wants the TCC grants on your terminal rather than on the app. In that mode the CLI prints `[stage-studio] recorder PID: <pid>`; `kill -TERM <pid>` stops it cleanly. Listen for the **Tink** sound — that's recording start; **Pop** is stop.

#### How the CLI talks to the app

A Unix domain socket at `~/Library/Application Support/Stage Studio/control.sock`, mode 0600, one JSON request per connection: `ping` / `status` / `start` / `stop` / `cancel`. A socket file was chosen over the alternatives on permission grounds — a URL scheme can't answer back, a localhost port can raise the firewall prompt, and Apple Events would add an Automation grant. A socket adds no TCC surface at all.

### 3. The hotkey app (no Claude session needed)

The capture pipeline is solid, but starting a recording used to require a Claude
session — so it didn't get reached for. `app/` is a standalone native front door
onto the *same* recorder. The Claude and CLI flows are untouched.

```bash
pnpm run build:app
ditto "app/build/Stage Studio.app" "/Applications/Stage Studio.app"
open "/Applications/Stage Studio.app"
```

Its permanent home is `/Applications/Stage Studio.app`. The bundle carries its
own copy of the recorder and the background art, so it keeps working with no
checkout present — don't point a login item at a build directory.

**Identity is frozen on purpose.** The bundle id `io.digitalpine.stage-studio`
is the key macOS files every permission grant under, and the app is signed with
a real Developer ID rather than ad-hoc. Together those give it a designated
requirement that is byte-identical on every rebuild, so Screen Recording and
Microphone grants survive rebuilds instead of resetting. Changing the bundle id
— or going back to ad-hoc signing — makes macOS treat it as a brand-new app and
forget every permission. Don't.

The build uses hardened runtime (needed for notarization later), which gates the
microphone behind `com.apple.security.device.audio-input` — hence the
entitlements file applied to both the app and the embedded recorder.

It's an agent app (`LSUIElement`) — no Dock icon, no window until you summon one.
There's a small menu-bar item, but that's a back pocket, not the interface: start
a recording, quit, and — the one thing the pill can't do — find a recording again
after its pill has faded.

**Recent Recordings.** The menu lists the last five saves, newest first; clicking
one reveals it in Finder, selected, exactly as clicking the saved pill's filename
does. Every recording goes through the app — hotkey, CLI, Claude — so every one
of them lands here, wherever `--output` pointed. Long names are middle-truncated
so the timestamp (the part that tells two takes apart) survives. A recording
you've since moved or thrown away stays listed, greyed and marked *— missing*,
rather than silently vanishing or beeping at you. The history lives in
`~/Library/Application Support/Stage Studio/recents.json` and survives relaunch.

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
APP="app/build/Stage Studio.app/Contents/MacOS/StageStudio"

# summon a surface, screenshot it, quit — self-cleaning
"$APP" --debug-show picker --debug-capture /tmp/picker.png
"$APP" --debug-show pill-recording --debug-capture /tmp/pill.png
"$APP" --debug-show pill-countdown --debug-midline   # midline = centering check
"$APP" --debug-show pill-saved --debug-hover         # filename's click affordance
"$APP" --debug-reveal                                # exercise the Finder reveal

# the status menu — opened for real, with the real history in it
"$APP" --debug-show menu --debug-capture /tmp/menu.png
"$APP" --debug-reveal-recent 0    # click its Nth recent item (disabled = no-op)

# the agent treatment — violet ring + "Claude · " attribution
"$APP" --debug-show pill-countdown --debug-agent --debug-midline
"$APP" --debug-show pill-recording --debug-agent --debug-label "Claude"

# drive the whole session against one window, then quit
"$APP" --debug-record "Safari" --debug-record-seconds 5
"$APP" --debug-record "Safari" --debug-record-seconds 3 \
       --debug-record-output /tmp/take.mp4   # somewhere disposable
```

`app/tools/inkbox` measures where text ink actually sits relative to a row's
midline in a screenshot, so "optically centered" stays a number rather than an
impression. Crop the shot to the capsule band first (`sips -c 76 <width>` — the
pill row is 38pt, and the shadow margin is symmetric, so the crop stays centred),
otherwise it measures whatever desktop is showing above and below the pill.

**Verifying the human override.** The one link that can't be exercised
synthetically is the physical `esc` press: the hotkey is a Carbon grab, and
injecting a keystroke would need an Accessibility grant this app deliberately
doesn't have. So the control surface exposes `escape`, which calls the very
function the key calls — no separate code path, and no waiter of its own, so what
it proves is that overriding an agent's session resolves that agent's pending
`start` as `cancelled`:

```bash
SOCK=~/Library/Application\ Support/Stage\ Studio/control.sock
echo '{"command":"escape"}' | nc -U "$SOCK"
```

#### CLI reference

```
  stage-studio [options]        start a recording through the app (default)
  stage-studio stop             stop the live recording, print the file
  stage-studio cancel           abort and delete the partial file
  stage-studio status           what the app is doing, as JSON
  stage-studio list-windows     on-screen windows as JSON

  -t, --duration <s>    seconds, or 0 for open-ended (5min cap either way)
  -o, --output <path>   final MP4 path (default ./out.mp4)
  -w, --window <pat>    target window pattern (case-insensitive substring)
      --window-id <N>   target specific CGWindowID (`stage-studio list-windows`)
      --label <name>    who the pill credits (default Claude)
      --source <who>    agent (default) or human — picks the pill's treatment
      --headless        bypass the app: direct recorder spawn, no pill
      --work-dir <p>    intermediate artifacts, headless only (default ./out)
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

The capture pipeline below is the `--headless` topology — the CLI spawning the recorder itself. On the default path the CLI hands the window id to the app over the control socket, and the app owns everything from the countdown to the finalized file; the recorder and its pipeline are identical either way.

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
- **SIGKILL on the recorder loses the recording.** It doesn't give AVAssetWriter time to finalize the MP4. Every normal stop path (the pill, `esc`, `⌥⌘R`, `stage-studio stop`) traps cleanly; only a hard kill of the app or a `--headless` recorder can lose a take.
- **A stop that arrives after you already stopped by hand reports `not_recording`.** The file is fine — the app finalized it when you hit `esc` — but the CLI's stop response can't tell that apart from "there was never a session". Check `stage-studio status` for the saved path.
- **Mac-only, single display, no webcam, no system audio (mic only).**
- **The hotkey app is signed but not notarized yet.** `spctl` rejects it as
  "Unnotarized Developer ID". A locally built copy has no quarantine flag so it
  launches fine; a copy that travels (DMG, download) would be blocked until
  notarization lands.
- **The hotkey app's hotkey is hardcoded to `⌥⌘R`.** No settings UI; if another
  app already owns that combination, registration fails and it says so on stderr.

---

## Repo layout

```
stage-studio/
├── .claude/skills/stage-studio/  Claude skill for the chat-driven flow
├── app/                       Hotkey recorder — LSUIElement agent app (Swift)
│   ├── Sources/               main, AppDelegate, picker, pill, session, hotkeys,
│   │                          ControlServer (the socket the CLI drives)
│   ├── Resources/             Info.plist, entitlements, icon-master.png
│   ├── tools/inkbox/          Measures text ink vs. a row midline in a shot
│   └── build.sh               → build/Stage Studio.app (Developer ID signed)
├── assets/                    Default background image
├── cmd/
│   ├── clicks/                CGEventTap mouse capture (Swift)
│   ├── windows/               CGWindowListCopyWindowInfo enumeration (Swift)
│   ├── recorder/              SCK + Core Image + AVAssetWriter pipeline (Swift)
│   └── gradient-preview/      Standalone renderer for background variants (Swift)
├── render/                    v1 Remotion compositor (backlogged)
├── src/
│   └── cli.ts                 Bun CLI — drives the app; --headless direct-spawns
├── test/                      v1 pixel-sampling validation harness
├── SHAPE-ui.md                Design rationale for Claude-as-UI
└── README.md                  this file
```

---

## License

MIT.
