# Build brief — one cohesive tool: Claude records through the app (DIG-793)

> **Historical — predates the 2026-07-30 rename to Windowclip.** Left verbatim on purpose: the product names, bundle id `io.digitalpine.stage-studio`, executable `StageStudio`, `~/Library/Application Support/Stage Studio/`, exp-clone paths and base commits below were all true when this brief was written, and the safety constraints in it were correct for the app installed at the time. For current identity see `README.md` and `app/Resources/Info.plist`.

Ticket: DIG-793 · Branch: `feat/agent-control` · Workdir: `~/Code/.exp-stage-studio/002-agent-control` ONLY. Base: main @ 9b9223d (includes the signed Stage Studio app).

## Intent

Two stacks share one engine today: the Claude path (CLI → headless recorder, invisible) and the app (hotkey → pill UI). Unify them: **the app becomes the single recording engine + UI; every recording — human- or agent-initiated — shows the pill.** This unlocks Joel's end state: Claude may (eventually, with his say-so) start recordings autonomously, and that's only acceptable because he can *see* it happening and *physically kill it*.

## Settled decisions

- **External control surface on the running app**: start (windowId, optional output path) / stop / cancel / status. Mechanism (URL scheme, local socket, CFMessagePort, …) is your call — it's internal and reversible — but constraints: cleanly callable from a shell/CLI, gives the caller real feedback (JSON/exit codes: session started, output path, user-cancelled, busy), no new TCC surface.
- **CLI routes through the app by default**: `stage-studio` record commands drive the app (auto-launching `/Applications/Stage Studio.app` if not running). The old direct-spawn path survives only behind an explicit `--headless` flag (autonomous/CI contexts). Big side win: recording permissions consolidate onto the app's signed identity — document that in README.
- **Update the in-repo `/record` skill** (`.claude/skills/record/SKILL.md`) to the new flow: app-routed start/stop, what the user sees (pill), how stop works now. Keep it accurate to what you build — the skill is the Claude-facing contract.
- **Agent-initiated recordings are visually distinct**: the pill shows who started it (e.g. "Claude · recording…" and a different accent from human sessions). Countdown still runs for agent starts — it's Joel's cancel window before capture begins.
- **Joel's physical controls always win**: Esc / pill click / ⌥⌘R stop or cancel ANY session, agent-initiated included. If an agent asks to record while a session is live → busy error, never queue/preempt. If the user stops an agent's session, the caller learns that in its status/stop response.
- **No scope creep into DIG-790** (notarization/DMG/onboarding stay deferred). No autonomous-trigger logic either — this ticket builds the *pipes and visibility*; when/what Claude auto-records is a later, separate shaping with Joel.

## Verification protocol — same religion as before [REQUIRED]

- See-don't-infer: screenshot real surfaces; midline-verify any new pill text state (the "Claude · recording" label especially).
- On-screen surfaces stay ephemeral (Joel is working on this machine): show → capture → tear down, pgrep-clean between cycles.
- **End-to-end proof of the unified path**: from a plain shell, drive `stage-studio` → app-routed recording of a real window: pill appears (screenshot it mid-session showing the agent-initiated state), stop via CLI, verify the MP4 (ffprobe H.264+AAC, real audio signal). Then verify the human-override path: the one link you may not be able to exercise synthetically (physical Esc) — use a debug hook to fire the same code path, and list the physical press as a Joel-test item in your report.
- Identity check: this rebuild carries the frozen bundle ID + Developer ID signature — grants should carry over with NO new permission prompt. If a prompt appears, identity broke: stop and report (that's a regression against 9b9223d, not something to work around).
- Install: kill the running instance, replace `/Applications/Stage Studio.app`, relaunch (login item already points there).

## Tripwires

Same as ever: mandatory early checkpoint — **stop and report once the control surface skeleton works end-to-end** (CLI can start/stop an app session and the pill visibly appears), before polish and skill rewrite. Above-brief structural calls, thrash (few same-error retries), or any permission prompt → stop and report. Commit small on `feat/agent-control`, reference DIG-793, push the branch; the lead merges after review.
