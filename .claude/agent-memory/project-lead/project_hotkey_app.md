---
name: hotkey-app-build
description: DIG-789 hotkey recorder app — state, locations, and settled decisions (started 2026-07-28)
metadata:
  type: project
---

DIG-789 ("Recording requires a Claude session — no standalone quick-capture entry point") is the v1 native front door: ⌥⌘R → picker (thumbnails) → countdown-in-pill → record via existing `cmd/recorder` → stop via pill/Esc/hotkey.

**Why:** the Claude-driven flow works but its friction stopped Joel from reaching for the tool. This deliberately supersedes SHAPE-ui.md's "no menubar / no global shortcut" exclusions (conscious reframe with Joel, 2026-07-28).

**SHIPPED 2026-07-28**: merged to main (fast-forward through 9b9223d), installed at `/Applications/Stage Studio.app`, login item set, Joel using it happily. Bundle ID **frozen: io.digitalpine.stage-studio** (TCC primary key — never change), signed with Developer ID (UQ27DB7N8K), hardened runtime on, bundle self-contained (recorder + bg art inside). Exp clone `~/Code/.exp-stage-studio/001-hotkey-app` is now retirable (`exp done`) — the app no longer depends on it.

**How to apply:** brief preserved at `BRIEF-hotkey-app.md` on main. Visual spec = runtime route `stage-hotkey-ui` (source `mockups/hotkey-ui/`), signed off by Joel after two feedback rounds. Settled: no pause, no settings, Esc hijack only while recording (dogfood), unsigned local build (no distribution ceremony — single-user phase), recorder binary interface unchanged. Joel's uncommitted Homebrew work (DIG-184) sits in the main checkout — don't disturb it.
