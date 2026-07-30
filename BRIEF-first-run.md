# Build brief — first-run setup for permissions (DIG-803)

Ticket: **DIG-803** — "No first-run setup flow for the permissions the app needs"
Branch: `feat/dig-803-first-run` · Workdir: `/Users/joel/Code/.exp-stage-studio/005-first-run-setup` **ONLY**
Base: `feat/dig-790-packaging` @ `3da7302` (carries the macOS-15 deployment floor + the DMG packaging script)

## Why this exists

Stage Studio works beautifully for Joel and cannot be handed to anyone else. He wants to give it to
his friend Art as the first external user. Signing, notarization and the install artifact are done —
Art can now *open* the app. What he cannot do is get it *working*, because the app needs Screen
Recording and Microphone grants and currently says nothing about them: there is no preflight check,
no request, no link into System Settings, no indication of what is missing (verified by inspection —
`CGPreflightScreenCaptureAccess` and `AVCaptureDevice.authorizationStatus` appear nowhere in
`app/Sources/`). A user without grants gets silent degradation.

Your job is the setup surface that turns "it doesn't work and I don't know why" into a guided,
finite, obviously-completable task.

## Settled — the flow

Approved by Joel before dispatch. Build this shape; raise anything that fights it rather than
quietly redesigning.

- **Appears only when something is missing.** All grants present → the app stays invisible exactly as
  it does today (it's `LSUIElement`; do not regress that). Do not show a welcome window to a
  correctly-configured user on every launch.
- **Also reachable on demand** from the status-item menu, because grants can be revoked later and the
  app must not become mysteriously broken with no way back.
- **Two permission rows**, each showing live status and its own action:
  - **Screen Recording** — read with `CGPreflightScreenCaptureAccess()`, prompt with
    `CGRequestScreenCaptureAccess()`. Granting does **not** apply to the already-running process, so
    once granted this row must resolve to a **"Relaunch to finish"** action that actually relaunches
    the app. Leaving the user to infer "quit and reopen" is the failure this row exists to prevent.
  - **Microphone** — read with `AVCaptureDevice.authorizationStatus(for: .audio)`, prompt with
    `requestAccess(for: .audio)`. In-app prompt, no relaunch needed.
- **Denied is a distinct state, not a retry.** Once denied, the app cannot re-prompt at all — that row
  must switch to opening the exact System Settings pane
  (`x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`, and the
  microphone equivalent). Verify the URLs actually land on the right pane; don't trust them from
  memory.
- **Forecast the second consent dialog.** After Screen Recording is granted, macOS still raises its
  own capture-time consent prompt on the first recording. This surprised Joel even though he had
  granted everything — it reads as the app being broken. You cannot pre-empt it, so *predict* it: one
  calm line telling the user macOS will ask once more the first time they record and that's expected.
  Predicted, it's a normal step.
- **The ready state teaches the hotkey.** Art has no way to discover ⌥⌘R. The terminal "you're all
  set" state is where he learns it. Reuse the existing `KbdChip` for the key rendering rather than
  inventing a second visual language for keystrokes.
- **Scope discipline:** no settings/preferences window, no account, no telemetry, no tour beyond the
  hotkey line. This is a permissions gate with a ready state, not an onboarding product.

## 🔴 Hard guardrail — never reset Joel's real grants

This is his live working machine and the app is in daily use.

**Do NOT run `tccutil reset ScreenCapture` / `tccutil reset Microphone` (or any `tccutil reset`) for
`io.digitalpine.stage-studio` or globally.** It would revoke the grants that make his installed app
work, and re-granting is a manual multi-step chore. This has no upside for you: it is not how you
test the ungranted states.

Instead, **make every state renderable on demand**, the way the existing debug harness already does
for the pill and picker. Read the `--debug-show` harness in `AppDelegate.swift` and extend that same
pattern so each row state (needed / granted / denied / needs-relaunch) and the ready state can be
forced and screenshotted without touching real permissions. That harness is also how the lead
verifies your work, so treat it as a deliverable, not scaffolding.

The genuine clean-slate test — a fresh local macOS user account, where TCC is empty for real — is the
lead's gate with Joel, **not yours**. Don't create user accounts.

## Verification — see, don't infer [REQUIRED]

Joel's standing directive: *"Because you are implementing design work in Swift, I would hope that you
would 'see it' as you build it and not infer the visual outcome just from the code."*

- **Screenshot every state of the real window** and actually look at the images. No visual claim
  without a capture behind it.
- **Dispatch the `visual-judge` subagent on your own screenshots** before concluding a state looks
  right. Brief it narrowly: the shot path, one line on what the thing is, and the question you want
  answered about the pixels. Withhold your code, your intent, and your own read — that withholding is
  the whole mechanism.
- **Match the existing design language.** Read `Theme.swift`, `PillView.swift`, `PickerView.swift`
  first and stay inside that vocabulary. Target: looks like it shipped with macOS. Do not introduce a
  new palette, corner radius scale, or type ramp.
- **On-screen surfaces stay ephemeral.** Joel is working on this machine — show, capture, tear down.
  Never leave a window sitting on his screen, and don't steal focus longer than a capture needs.
- **Instruments:** the repo already has what you need (the debug-show/capture harness, `app/tools/inkbox`).
  If you find yourself needing a *measurement* capability that doesn't exist — pixel sampling, timing,
  anything whose output would become a recorded fact — **stop and report the gap**. Do not improvise
  one mid-task; invented instruments mint wrong facts that outlive the run.

## Stages — stop and report at each boundary

You have a fresh transcript and no track record with me yet, so the leash is short and the first stop
is deliberately early. Each report should be self-sufficient enough that a *successor with none of
your context* could pick up from it: decisions made, state on disk, branch/commits, what's verified
vs assumed, what's next. Transcripts are mortal; your stage report is the real continuity substrate.

**Stage 1 — interpretation-revealing. Design the state model and render it. Then STOP.**
Read the existing app first (`AppDelegate.swift`, `Theme.swift`, `PillView.swift`, `PickerView.swift`,
the debug harness). Define the state model — what states exist per row, what the window looks like in
each — build the window so every state can be forced via the debug harness, and screenshot them all.
Report with the shot paths and your state model *before* wiring any real permission API. This is where
I catch a misread while it's still cheap, so show me how you understood the task, not just what you
typed.

**Stage 2 — real detection and actions.** Wire preflight/status reads, the two request paths, the
relaunch action, and the Settings deep links. The *granted* path you can verify live (Joel's machine
has the grants); the missing/denied paths are verified through the debug harness per the guardrail
above. Verify the deep links actually open the correct pane. Report.

**Stage 3 — integration.** Launch gating (show only when something's missing, stay invisible
otherwise), the status-menu entry point, the ready state with the hotkey, the forecast line about
macOS's second prompt. Report.

## Tripwires — stop and report, don't grind

- **Any structural or product decision the brief didn't settle** — especially anything that changes
  what ships, where code lives, or the app's existing behavior. Escalate; don't decide it.
- **Thrash**: a few retries of the same failure with no new information. Report what you have so far
  so partial work is salvageable. An early flag usually reveals a fixable gap and costs far less than
  a long opaque loop.
- **A capability you'd have to build or improvise to proceed** — report the gap precisely and deliver
  whatever doesn't depend on it.
- **A permission prompt you didn't intend to trigger**, or any sign that a real grant changed state.
  Stop immediately and report — that's Joel's working setup.

## Mechanics

- Commit small on `feat/dig-803-first-run`, reference DIG-803, push the branch.
- **Do not merge to main. Do not reinstall `/Applications/Stage Studio.app`** — the lead handles
  rollout with Joel.
- **Never touch `/Users/joel/Code/stage-studio`** (the canonical checkout) — it holds unrelated
  uncommitted work on another branch. Your clone only.
- Build with `pnpm run build:app` (or `./app/build.sh`). It signs with Developer ID and the bundle ID
  is **frozen** at `io.digitalpine.stage-studio` — never change it; it's the TCC primary key and
  changing it forfeits every grant.
- Process-name gotcha: the executable is `StageStudio` (no space) inside "Stage Studio.app", so
  `pgrep -x "Stage Studio"` is a permanent false negative. Positive-control any process probe before
  trusting its negative.

---

# Stage 1 — COMPLETE and approved. Stage 2 handoff.

Written by the lead after reviewing stage 1. The stage-1 builder's transcript expired before it could
be resumed, so this section is the continuity substrate: it carries everything a successor needs
without that transcript. If you are picking this up cold, **this section is your starting point.**

## State on disk (verified)

- Branch `feat/dig-803-first-run` @ **`ad9ad43`** ("DIG-803: render every first-run permission state"),
  pushed, on top of `3da7302`.
- New: `app/Sources/SetupView.swift` (state model + SwiftUI view), `app/Sources/SetupController.swift`
  (the window).
- Touched: `Theme.swift` (additive setup-window metrics), `AppDelegate.swift` (`runDebugSetup`, two
  `LaunchOptions` fields), `main.swift` (`--debug-screen` / `--debug-mic`), `README.md`.
- Screenshots of all seven states in `.screenshots/dig803/` (gitignored, on disk).
- Joel's installed app was never touched, never reinstalled, and no permission API was called anywhere.

## The approved state model — do not redesign it

A row is **one permission × one of four states**, and the states are not variants of "off" — each has a
*different correct action*:

| state | means | action |
|---|---|---|
| `needed` | the system prompt can still be raised | `Allow…` |
| `granted` | done | green ✓ + "Allowed", no button |
| `denied` | macOS will never prompt this app again | `Open Settings` — a retry button here would do nothing |
| `needsRelaunch` | grant exists but not for *this* process | `Relaunch` |

`needsRelaunch` is **Screen Recording only**; the harness deliberately rejects `--debug-mic relaunch`,
because a mic grant applies immediately and a screenshot of that state would be a fabricated fact.
Keep that guard. Window-level state is derived, not stored (`isReady` = both granted). Granted rows
stay visible when ready so the status-menu "is everything OK?" case answers itself.

Render any state (self-terminating, reuses the existing `armCapture`/`captureRegion` contract — no new
capture machinery):

```
"app/build/Stage Studio.app/Contents/MacOS/StageStudio" --debug-show setup \
  --debug-screen <needed|granted|denied|relaunch> \
  --debug-mic <needed|granted|denied> \
  --debug-capture <png>
```

## Settled design decisions — approved, leave alone

- A real **titled `NSWindow`** (transparent titlebar + `fullSizeContentView`, movable by background,
  Esc closes), not a borderless HUD. The user leaves this window to visit System Settings and must be
  able to find their way back.
- **Close-only traffic light** (Finder Get Info precedent). Settled; don't revisit.
- App stays **`.accessory`** while the window is up. Exits are Esc, the close box, and Done.
- The macOS-asks-again forecast line shows whenever Screen Recording is granted (superset of the
  original ask). Keep.
- Count-agnostic header ("Stage Studio needs your permission"). Keep.
- The eyebrow + mono `stage-studio` header is the **picker's own vocabulary**, which Joel signed off
  on. Two visual judges flagged it in isolation and were overruled deliberately — consistency with a
  shipped surface beats a cold read of one window. Do not "fix" it.

## Stage 2 — corrections first, then the real wiring. Then STOP.

**1. Button hierarchy — Joel's decision: guided sequence.** Only the *topmost unresolved* row gets the
prominent blue button; every other actionable row is secondary/bordered. macOS wants one default
button per window; two equal blues gave the eye no entry point, made Return ambiguous, and left the
both-denied state with no clear default. Granted rows are not actionable at all.

**2. The ready-state copy makes a promise the app can't keep.** It currently says "allow it and it
won't ask again." Sequoia-era macOS re-prompts for screen recording periodically — very likely what
surprised Joel originally. If it recurs, that line converts normal macOS behavior into evidence the
app lied. Rewrite so it is true regardless of Apple's cadence: name it as macOS being careful and
something to expect. **Do not substitute a different frequency claim** — the cadence isn't known, so
don't assert one.

**3. Verify legibility over a light background.** The window is translucent and contrast was judged
over Joel's dark desktop (wallpaper bleed is visible through the bottom of `07-ready`). Art's
wallpaper is unknown. **Do not change Joel's wallpaper** — park the window over a white/light window
and re-shoot. If secondary copy or the footnote degrades, thicken the material or scrim behind the
text rather than darkening the whole window.

**4. Fix the centering race** flagged in stage 1 (`window.center()` likely racing `setContentSize`):
make the frame final before centering.

**Then the real wiring:** status reads, both request paths, the relaunch action, and the Settings deep
links — **verifying each deep link actually lands on the correct pane** rather than trusting a URL
constant from memory. Close System Settings after checking; Joel is working. Stage 2 plugs into
`SetupController.onAction` and `SetupModel`. `Info.plist` already carries
`NSMicrophoneUsageDescription` and both binaries are signed with the audio-input entitlement, so
nothing new is needed there.

## 🔴 Stage-2 hazards — the leash is short here because of stakes, not performance

Stage 1 was clean. Stage 2 is the first code that touches real TCC state and can relaunch a running
app, on Joel's live daily-driver machine.

- **Your build and Joel's installed app share the frozen bundle ID**, so they compete for the ⌥⌘R
  hotkey and for `~/Library/Application Support/Stage Studio/control.sock`. Debug runs must stay
  self-terminating and must never leave an instance resident. **Never kill or relaunch the installed
  app's process** — only ever your own bundle inside this clone.
- **Nothing may revoke a grant. Still no `tccutil`, in any form.** Requesting an *already-granted*
  permission is a safe no-op, and that is the only real-API path to exercise against live state.
- Focus theft can silently clobber a capture mid-flight (it happened once in stage 1). Re-shoot any
  capture you didn't watch land.
