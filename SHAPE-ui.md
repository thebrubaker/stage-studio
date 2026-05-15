# Shape: Claude as the UI

> Status: shaped, not built. Decided 2026-05-15 to skip the SwiftUI app path
> (full shape preserved as `SHAPE-ui-swiftui-rejected.md`). Claude itself
> becomes the picker/controller via the existing `AskUserQuestion` tool.

## Insight

Building a SwiftUI app to ask Joel "which window?" / "still recording, stop?"
is solving a problem that's already solved — Joel is already talking to Claude.
Claude has `AskUserQuestion` and can already display data (images, lists).
We don't need a *second* UI surface. We just need the CLI to expose the right
hooks for Claude to drive cleanly.

This collapses the 2-day SwiftUI build into a few hours of CLI ergonomics.

## The full flow this enables

```
Joel:    "record a short clip of this Linear ticket"
Claude:  [runs `cmd/windows list --thumbnails /tmp/winshots`]
         [sees 8 windows, picks top 4 most likely candidates]
         [uses AskUserQuestion with thumbnails:
            • Linear — DIG-228 Agent Runner Phase 2
            • Linear — Backlog (Side Projects)
            • Slack — #d-dev
            • Chrome — onbook]
Joel:    picks one
Claude:  [runs `bun run cli --window-id 8721 --duration 0 --output ./clip.mp4`]
         [spawns recorder in background, captures PID]
         "Recording the Linear window. Say 'stop' anytime."
Joel:    "stop"
Claude:  [SIGTERMs the recorder PID]
         "Stopped. Output: ./clip.mp4 (12 seconds)"
```

No app to open. No second UI surface. Joel is already in the chat; Claude is
already there. The CLI just needs to expose the right primitives.

## What needs to change (concrete CLI deltas)

### 1. `cmd/windows`: add thumbnail dump mode — *~1 hour*

```
cmd/windows list                           # existing — JSON only
cmd/windows list --thumbnails <dir>        # NEW — also writes <dir>/<windowID>.png
```

Implementation: for each window in the result, use `CGWindowListCreateImage`
(legacy, no Screen Recording prompt for off-screen-rect) or
`SCWindow.previewImage` (modern, may need permission) to dump a small PNG.
Static snapshot is fine — Claude doesn't need live thumbnails.

Output JSON gets a `thumbnailPath` field pointing at the dumped PNG.

### 2. `cmd/recorder`: open-ended duration + SIGTERM graceful stop — *~1 hour*

Today the recorder runs for a fixed `<durationSeconds>` and exits. Change:
- `durationSeconds = 0` means "run until SIGTERM"
- SIGTERM handler: stops the SCK stream, marks inputs finished, finalizes the
  AVAssetWriter, exits 0
- Verify the writer doesn't lose the trailing buffers if the signal arrives
  mid-frame

This is the *real* UX win — Joel can say "stop" at any moment and Claude
finalizes the recording immediately.

### 3. `src/cli.ts`: add `--window-id <CGWindowID>` flag — *~30 min*

Today: `--window <pattern>` does fuzzy substring match. Fine for Joel typing,
fragile for Claude piping the exact ID from `cmd/windows list`. Add the
numeric form so Claude never relies on title matching.

### 4. Background-spawn ergonomics in cli — *~30 min*

When `--duration 0`, the CLI:
- Spawns recorder in the background
- Prints the recorder PID to stdout (so Claude can capture + SIGTERM it later)
- Exits immediately, leaving the recorder running

Or alternatively: cli stays foreground and Claude SIGTERMs the CLI, which
propagates to the recorder. Either works. The PID-print form is simpler for
Claude.

## Why this is right

- **No second UI surface.** Joel's already in chat; Claude is already there.
- **No `.app` bundling, no entitlements drama.**
- **CLI stays the canonical entrypoint.** Autonomous Claude-driven recordings
  (no Joel interaction) still work with `--duration N` like today.
- **Thumbnails-via-chat is no worse than thumbnails-via-app** — Claude can
  display PNGs inline and put 4 windows in an `AskUserQuestion` with preview
  text. The picker UX is roughly equivalent without the build cost.

## Out of scope (firm)

- No pause/resume. Just start and stop. If Joel needs to pause, he stops and
  starts a fresh recording — same outcome with less mechanism.
- No "remember last window" — Claude can hold that in conversation context.
- No global keyboard shortcuts.
- No menubar presence.

## Rabbit holes / risks

1. **Thumbnails permission.** `CGWindowListCreateImage` traditionally worked
   without prompts; on recent macOS it may require Screen Recording. SCK's
   `SCWindow.previewImage` definitely does. Worth testing both. Mitigation:
   we already have Screen Recording granted (recorder needs it), so this
   should not be a new permission.

2. **SIGTERM mid-frame.** AVAssetWriter doesn't love being interrupted while
   appending a sample. Mitigation: signal handler sets a "stopping" flag; the
   stream output handler checks it and stops appending; *then* we call
   `stream.stopCapture()` + `markAsFinished()` + `finishWriting()` from the
   main task. ~30 min of careful sequencing.

3. **PID capture and propagation.** If cli.ts spawns recorder and exits,
   the recorder needs to be `setsid()`'d (or equivalent) so it doesn't die
   with the parent shell. Bun's `spawn` with `detached: true` should handle
   this. Need to verify the PID printed is the recorder process, not Bun.

4. **AskUserQuestion image rendering.** Claude can show images from disk via
   the Read tool but may not embed them inline in the AskUserQuestion options.
   Worst case: Claude posts the thumbnails first as a multi-image preview,
   then asks the question. Slightly less elegant but works.

## Open questions for Joel

1. **Foreground-with-Ctrl-C, or background-with-PID?** Both work; the PID
   form lets Claude drive stop from another tool call without blocking. The
   foreground form is simpler to test. I'd default to background.
2. **Thumbnails in this batch, or defer?** Skipping them means Claude picks
   by app+title text alone. Lower lift but slightly worse UX. I'd include
   them — they're cheap.

## Build estimate

**~3-4 hours total.** Order:
1. recorder SIGTERM + duration=0 (1h)
2. cli `--window-id` + background spawn + PID print (1h)
3. windows `--thumbnails` mode (1h)
4. End-to-end test: Claude drives the full flow against this very session (30m)

If you greenlight this, I'll execute it as a single batch and hand back a
working "say record / pick window / say stop" loop.
