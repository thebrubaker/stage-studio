---
name: visual-verification-joel
description: Joel's directives on verifying visual/design work in this project — see it, don't infer; his eye beats instruments
metadata:
  type: feedback
---

For design work in this project: **render and look — never infer visual outcome from code.** And when Joel says something looks off, treat his eye as ground truth even against instrument readings.

**Why:** (1) Joel, verbatim: "Because you are implementing design work in Swift, I would hope that you would, quote-unquote, 'see it' as you build it and not infer the visual outcome just from the code." (2) Validated incident 2026-07-28: foveate's optical-centering number pointed the wrong direction (said ink low; it sat high), visual-judge confirmed the wrong verdict using the same meter, and Joel's naive method — a midline hairline across the container + boxes on child elements — settled it in one glance. Field-reported to the foveate maintainer (foveate:1008).

**How to apply:** native app surfaces get debug flags to summon each state; screenshot real windows (`screencapture -l <windowID>`) and Read the PNG before any visual claim. **On-screen test surfaces must be ephemeral**: this is Joel's live working machine, so show → capture → kill immediately (never leave a floating panel up while analyzing); verify no test process lingers (Joel, 2026-07-28: leftover surfaces block his work). For centering questions, the hairline+child-boxes overlay is the preferred first instrument. Draw overlays post-capture-thin (a 1px DOM line magnified 8× reads as a fat stroke — Joel flagged it). Optical (ink) centering over geometric box centering, in web mockups and Swift alike.
