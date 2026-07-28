# Build brief — stage-studio hotkey recorder (DIG-789)

Ticket: DIG-789 · Branch: `feat/hotkey-app` · Workdir: this exp clone ONLY (`~/Code/.exp-stage-studio/001-hotkey-app`). Never touch `~/Code/stage-studio`.

## Intent

Stage-studio's capture pipeline is proven, but starting a recording requires a Claude session — so it doesn't get reached for. Build the standalone native front door: **global hotkey → window picker → countdown → record → minimal stop pill.** The Claude/CLI flow stays untouched; this is an additional entry point.

## Settled decisions (do not relitigate; escalate if one comes unsettled)

- **Flow**: ⌥⌘R (hardcoded v1) summons a centered window-picker panel (thumbnail grid, arrow keys + Enter, click, Esc closes). Pick → bottom-center pill appears and counts down 3·2·1 (names the target app; Esc cancels, nothing written) → same pill flips to recording state (red dot, mono elapsed, Stop). Stop via pill click, Esc, or ⌥⌘R again → pill flashes "Saved ✓ filename · duration", fades ~4s. Output: `~/Desktop/recording-<timestamp>.mp4`.
- **Esc is hijacked only while the pill is up** (countdown or recording) — via Carbon `RegisterEventHotKey`, registered on session start, unregistered on end. Zero new permission types. Same API for ⌥⌘R.
- **No pause. No menubar-centric UI** (a minimal status item as quit escape-hatch is fine, but it is not the interface). **No settings UI.**
- **The recorder is not rewritten.** The app spawns the existing `cmd/recorder` binary: `recorder <windowID> 0 <outputPath>` (env `RECORDER_BG_IMAGE` for background — see `src/cli.ts` for the exact contract), SIGTERM = clean finalize. Cancel = SIGTERM + delete the output file. 5-min safety cap is built in.
- **App shape**: LSUIElement (no Dock icon) SwiftUI/AppKit agent app living in `app/` in this repo. Unsigned local build — NO signing/notarization/distribution work (single-user phase; that machinery is deliberately out).
- **Window enumeration**: reuse the logic/approach of `cmd/windows` (CGWindowList, layer 0, ≥100px, excludes self). Thumbnails via `SCScreenshotManager` (modern; Screen Recording perm covers it).

## Design language — Mac-native, not web-translated

The React mockup in `mockups/hotkey-ui/` is the agreed **approximation** — match its layout, hierarchy, spacing, and states, but render them with native materials: `NSVisualEffectView`/`.ultraThinMaterial`-class blur for the picker, SF Pro, SF Symbols for all keyboard glyphs (arrows uniform — Joel explicitly flagged mixed-looking Unicode arrows), real app icons via `NSWorkspace.shared.icon(for:)` filling the label row height (~24pt square). Specifics carried from mockup review:

- Picker: dark material panel, 3-col thumbnail grid, selected cell = accent ring, footer kbd hints with breathing room.
- Pill: near-black rounded-full, the ONLY chrome on screen; red recording dot; **optical vertical centering** — Joel personally caught text riding high in the mockup; center *ink* (cap-height/baseline), not just the layout box, and verify it visually with a midline overlay or measurement, not by trusting the layout system.
- Pill window must float above everything, ignore mission-control spaces churn, and never steal key focus from the app being recorded (non-activating panel).

## Verification protocol — SEE it, never infer it [REQUIRED]

Joel's explicit directive: *"I would hope that you would 'see it' as you build it and not infer the visual outcome just from the code."*

- Give the app **debug flags** so every surface can be summoned deterministically without a hotkey or real recording: e.g. `--debug-show picker`, `--debug-show pill-countdown`, `--debug-show pill-recording`, `--debug-show pill-saved`.
- Screenshot the **real rendered windows**: find the app's window via the repo's own `cmd/windows/windows list` (dogfood) or `CGWindowList`, then `screencapture -l <windowID> -o /tmp/<name>.png`, then **Read the PNG and look** before claiming anything about appearance. (Your shell inherits cmux's Screen Recording grant, so `screencapture` works from the start.)
- Compare against the mockup views (`mockups/hotkey-ui/` — run route or read the TSX for exact spacing/opacity values as reference, translating to native idiom).
- End-to-end proof at the finish: a real recording driven through the full flow — picker → countdown → record a few seconds → stop — then verify the MP4 exists, `ffprobe` shows H.264 + AAC tracks, and open it once. A file existing is not a working recording.

## Tripwires — stop and report UP (don't guess, don't grind)

Report by **stopping with a clear status** (I resume you); mention the project lane topic `stage-studio` context in your report.

1. **First checkpoint (mandatory, early):** after the app skeleton + ONE surface (the pill) renders and you've proven the debug-flag + screencapture loop with an actual screenshot — STOP and report: how you structured the app, the shot itself, and anything that surprised you. This is the interpretation-revealing slice; do not build past it before reporting.
2. **TCC permission prompts**: the *app* needs its own Screen Recording grant the first time it calls SCK (thumbnails/recording). When macOS prompts, a human must click — stop and report so Joel can grant it.
3. **Any above-brief decision**: repo restructuring beyond `app/`, changing the recorder binary's interface, hotkey conflicts with system shortcuts, anything that smells like a structural call this brief didn't settle → tripwire, stop, name it.
4. **Thrash**: a few retries of the same failure with no new information (build system, panel behavior, AX quirks) → stop and report partial work + where you're stuck. Early stop beats a long opaque loop.

## Hygiene

- Commit as you go on `feat/hotkey-app` (small, honest commits; include the mockups/ dir in an early commit as the visual spec). Do not push.
- Build system: follow the repo's spirit (simple, swiftc/SPM — your call, it's not structural) with a `pnpm run build:app`-style script wired into package.json like the other binaries. Document the app in README when done.
- End with: what works, what's verified (with shot paths), what's left.
