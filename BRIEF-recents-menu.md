# Build brief — recents in the status-item menu

Branch: `feat/recents-menu` · Workdir: `~/Code/.exp-stage-studio/003-recents-menu` ONLY · Base: main @ 055bba3 (app-as-engine, socket control surface). Ticket ID arriving as a DIG number — reference it in commits once the lead passes it along; until then reference "recents-menu".

## Intent

Recordings land wherever `--output` pointed and the saved pill fades — after that, past recordings are findable only by memory. Joel: the status-item menu should list the **last five recordings** (names truncated); **tapping one opens Finder with that file selected**. "Sometimes there's going to be stuff and I won't know where they are from the past that I want to find."

## Settled

- **History is recorded by the app** at save-time (every session goes through the app now — human and agent alike). Persist it (UserDefaults or a small JSON in Application Support — your call) so it survives relaunch. Store full paths; render truncated (middle-truncation preserves the timestamp suffix — the distinguishing part).
- **Menu**: a "Recent Recordings" section in the existing status-item menu, newest first, max 5. Tap → `activateFileViewerSelecting` (same reveal the saved pill uses — reuse `revealInFinder`). A file that no longer exists at tap time: disable or remove the item gracefully, never a beachball or silent no-op — your call on which, but handle it.
- Cancelled sessions (no file) never enter history. The 5-cap trims oldest.
- No settings, no clear-history UI, no thumbnails — this is a five-line menu, not a library. Resist scope growth.

## Verification & discipline (same religion — see prior briefs on main)

- See-don't-infer: screenshot the open menu (real window) with ≥2 real entries; verify a tap reveals the right file in Finder (debug hook for the action + one AppleScript check of Finder's selection is fine).
- Missing-file path: delete a history file, verify the menu handles it as designed.
- Relaunch persistence: kill + relaunch the app, history intact.
- On-screen surfaces ephemeral; pgrep-clean between cycles; zero permission prompts expected (no new surfaces — a prompt = stop and report).
- Stop-and-report on: any structural surprise, any capability you'd have to invent, thrash. Checkpoint: this is small enough for a single report at the end — but if the status-item menu code doesn't exist yet in the shape you expected (it may be minimal), stop and report BEFORE restructuring it.
- Commit small on `feat/recents-menu`, push the branch, report with shot paths. Do not merge; do not reinstall /Applications (the lead handles rollout with Joel).
