---
name: stage
description: Record a polished MP4 of a single macOS window — gradient background, drop shadow, mic audio — driven from a Claude chat. Use when Joel says things like "let's record a video of this", "make a clip", "demo this in a recording".
---

# Clickzoom — Claude-driven recording flow

You are the UI for this tool. The CLI exposes the right primitives; you compose them into a conversational flow around `AskUserQuestion`, background bash tasks, and SIGTERM.

## When to use this skill

Joel says something like:
- "let's make a video / clip / recording of this"
- "record what we just built"
- "demo this in a short clip"
- "I want to share this — record it"

Or you proactively suggest it when something demoable just landed.

## The canonical flow

### 1. Identify the target window

Run:

```bash
~/Code/stage/cmd/windows/windows list
```

Returns JSON array of all on-screen windows. Each entry has `windowId`, `app`, `title`, `bounds`.

**Pick contextually if the target is obvious from conversation.** If we've been talking about "the Onlook calendar in Chrome," and there's exactly one Chrome window with "Calendar" in the title, that's the answer — pick it without asking.

**Ask if ambiguous.** Use `AskUserQuestion` with up to 4 candidate windows + "Other" auto-included. Label each by app and a short title slug:

```
Question: "Which window should I record?"
Options:
  - Linear — DIG-228
  - Chrome — onbook
  - Slack — #d-dev
  - Cursor — stage
```

Remember the chosen `windowId` for the next step.

### 2. Pick an output path

Default location: `~/Code/stage/out/<slug>-<YYYYMMDD-HHMMSS>.mp4` where `<slug>` is a short description of what's being recorded. Don't ask Joel about the path — he doesn't care, and a sensible default lets the flow stay conversational. He'll tell you if he wants it somewhere specific.

### 3. Start the recording (background, open-ended)

```bash
cd ~/Code/stage && bun run src/cli.ts \
  --duration 0 \
  --window-id <CGWindowID> \
  --output <output-path>
```

**Use `run_in_background: true` on the Bash tool call.** You'll get a task ID back.

**Capture the recorder PID** by reading the task output file. The CLI prints a line like:

```
[stage] recorder PID: 12345
```

That number is what you'll SIGTERM later. Hold onto it in conversation context.

After starting, surface a brief confirmation to Joel:

> Recording **Linear — DIG-228**. Say "stop" when you're done.

### 4. Wait for the stop signal

Joel will say something like "stop", "done", "that's it", "cut", or just send a message indicating the demo is over. When you see that:

```bash
kill -TERM <recorder-pid>
```

The recorder traps SIGTERM, finalizes the MP4, exits 0. The CLI exits 0 right after. The background bash task completes.

### 5. Surface the result

Read the task output file to confirm the recorder wrote the file. Tell Joel where the output landed and offer next steps (open it, attach to a message, etc):

> Done. `out/dig228-20260515-153012.mp4` (12s). Want me to open it?

## Important constraints

- **Recording duration safety cap: 5 minutes.** Even with `--duration 0`, the recorder hard-stops at 5 min so a forgotten recording doesn't fill the disk. If a longer clip is needed, set `--duration <seconds>` explicitly.
- **X press = lose the recording.** If Joel hits X on the background bash task in Claude Code's UI, the recorder gets SIGKILL'd before it can finalize. The MP4 will be corrupt. The clean stop mechanism is "say stop to Claude → SIGTERM." Mention this if Joel asks how to abort vs. stop.
- **Pause is not supported.** If Joel needs to pause, the workflow is "stop, set up, start a fresh recording." Document the gap if asked.
- **First run prompts for permissions.** Screen Recording, Microphone, Accessibility, Input Monitoring. All grants go to the parent terminal app (cmux). Input Monitoring requires terminal restart to take effect.

## Permission troubleshooting

If recording produces a black / blank output silently: Screen Recording permission missing on cmux. Joel grants it in System Settings → Privacy & Security → Screen Recording, then restarts cmux.

If audio track is silent: Microphone permission missing. Same fix.

If clicks/cursor data missing (not critical for v3 output but captured for future overlays): Input Monitoring missing.

## What this skill does NOT cover

- **Editing.** Joel does not want a post-recording editor. The recording IS the deliverable. Don't propose trim/cut/transitions.
- **Multiple windows.** One window at a time.
- **Background customization.** Single warm gradient default. Don't ask Joel to pick a background.

## File reference

- `cmd/windows/windows` — Swift binary, modes: `list`, `frontmost`, `find <pattern>`. JSON to stdout.
- `cmd/recorder/recorder` — Swift binary, takes `<windowID> <durationSeconds> <outputPath>`. Traps SIGTERM/SIGINT for clean stop.
- `src/cli.ts` — Bun wrapper. Orchestrates clicks recorder + recorder. Prints recorder PID to stdout.
- `.claude/skills/stage/SKILL.md` — this file.
- `SHAPE-ui.md` — design rationale for the Claude-as-UI approach.
- `README.md` — full architecture write-up.
