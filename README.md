# clickzoom

CLI tool that records a macOS window + mic and renders a polished MP4 with the window posed on a styled 16:9 background.

This is a personal prototype testing the thesis that the primitives for a Screen Studio clone are now cheap enough that the whole tool is a weekend solo build, not a product.

**Mac-only, CLI-only, single display.**

## Status

- **v3 (current):** SCK captures a single window → Core Image composites onto styled 16:9 canvas (gradient, drop shadow, padded) → AVAssetWriter outputs final MP4 with mic audio. One Swift process, no Remotion, hardware-accelerated end to end.
- **v2.x (deprecated):** captured to HEVC-with-alpha MOV intermediate, composited through Remotion. Removed because Remotion's pipeline silently flattens source alpha — see [DEVLOG](#v23-failure-mode-alpha-lost-in-remotion) below.
- **v1 (backlogged):** zoom-on-click + cursor tracking. The renderer (`render/src/Clickzoom.tsx`) and self-validation harness (`test/`) remain in repo as reference. See "v1 backlog" below for the parked design.

## Quick start

```bash
# one-time
bun install
pnpm install --dir render
pnpm run build    # compiles all three Swift binaries (clicks, windows, recorder)

# record a target window + render onto styled canvas (8 second default)
bun run cli --duration 10 --window "Linear" --output ./out/demo.mp4

# or let it pick whichever non-terminal window is frontmost when recording starts
bun run cli --duration 10 --output ./out/demo.mp4
```

Listen for the **Tink** system sound — that's the cue to start clicking. The CLI exits with the rendered MP4 written to `--output`.

## What you need (one-time)

Grant **all four** of these permissions to your terminal app (cmux, Terminal, iTerm, whatever you're running clickzoom from). Restart the terminal app after enabling Input Monitoring — that grant doesn't take effect until the app restarts.

- **Screen Recording** (Privacy & Security → Screen Recording). Required for ScreenCaptureKit. Without it the recorder produces empty/blank output silently.
- **Microphone** (Privacy & Security → Microphone). Required for AVCaptureSession audio. Without it the recorder still works but with no audio track.
- **Accessibility** (Privacy & Security → Accessibility). Required for `CGEvent.tapCreate` to succeed.
- **Input Monitoring** (Privacy & Security → Input Monitoring). Required for mouse-button events to reach the tap. With this missing, cursor *move* events still arrive but *click* events are silently filtered upstream.

Plus the usual toolchain: `ffmpeg` (used for ffprobe + frame extraction, not capture), `swift` (Xcode CLT), `bun`, `pnpm`.

## How it works (v3)

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
                          │ cmd/recorder (Swift, owns    │
                          │ the whole pipeline)          │
                          │                              │
                          │ SCK capture (window-only,    │
                          │   BGRA with alpha)           │
                          │      ↓                       │
                          │ AVCaptureSession mic         │
                          │      ↓                       │
                          │ Core Image compositor        │
                          │ (Metal-backed CIContext)     │
                          │  - linear gradient bg        │
                          │  - alpha-shaped drop shadow  │
                          │  - aspect-fit + pad window   │
                          │      ↓                       │
                          │ AVAssetWriter H.264 + AAC    │
                          └────────────┬─────────────────┘
                                       ▼
                                   output.mp4
```

**One process, hardware-accelerated end to end.** SCK captures only the target window's actual rendered content (occlusion-immune); Core Image (with Metal backing) composites each frame onto a styled background using the window's native alpha mask as the shape (so corners curve correctly across every app); AVAssetWriter encodes the composite directly to MP4 with muxed mic audio. No Remotion, no intermediate file, no headless Chromium.

**Window detection:** `cmd/windows/main.swift` queries `CGWindowListCopyWindowInfo` for on-screen windows. Modes: `list`, `frontmost` (excludes the calling terminal), `find <pattern>` (substring match on app + title). Returns `windowId` (a `CGWindowID`).

**Capture + compose:** `cmd/recorder/main.swift` uses **ScreenCaptureKit** with `SCContentFilter(desktopIndependentWindow:)`. The captured `CMSampleBuffer` carries `BGRA` pixels with alpha=0 at the window's corner gaps. A Core Image `Composer` (built on a Metal-backed `CIContext`):
- builds a `CILinearGradient` background at output dimensions (1920×1080) once at init
- per frame: scales+positions the source inside the canvas with padding, builds a drop shadow from the window's own alpha mask (`CISourceInCompositing` + `CIGaussianBlur` + offset), composites bg → shadow → window
- renders the composite to a pooled `CVPixelBuffer` and wraps it as a new `CMSampleBuffer` preserving the source's timing

The window's natural rounded corners come through automatically — no per-app radius matching, because the alpha mask *is* the window shape.

## CLI flags

```
clickzoom --help
  -t, --duration <s>    recording duration in seconds (default 8)
  -o, --output <path>   final MP4 path (default ./out.mp4)
      --work-dir <p>    intermediate artifacts (default ./out)
      --display <n>     avfoundation video device index (default: auto-detect)
      --mic <n>         avfoundation audio device index (default: auto-detect)
      --skip-record     reuse last recording, re-render only
  -w, --window <pat>    target window pattern (case-insensitive substring;
                        default: frontmost non-terminal window)
      --no-compose      skip styled-canvas composite; fall back to v1 Clickzoom
                        composition (zoom-on-click, currently backlogged)
```

The `--skip-record` flag is the tuning loop: record once, then iterate on Remotion constants without re-recording.

## v1 backlog: zoom-on-click

The original direction was auto-zoom-on-click — a subtle camera pointer drawing the viewer's eye to where you click. Three iterations on cursor tracking taught us:

- **Anchoring math:** transform-origin is *not* visible-center. Use `translate(-tx, -ty) scale(s)` with origin top-left so `tx = S*click.x - W/2` puts the click at output center. Clamp `tx ∈ [0, W*(S-1)]`.
- **Cursor tracking is hard to get right:** chasing the cursor every frame yanks the camera away from where the user clicked. The delta-relative tracking we built (anchor at click + cursor movement since click) helps but the effect still feels too strong in real use.
- **Dwell-commit:** a click only becomes a zoom event if the cursor stays near the click for ~300ms after. Drops transit clicks. Worked correctly in the harness, didn't feel right in practice.

**Why backlogged:** the effect comes off too strong even when math is right, and the user attention required to validate edge cases ("did the camera follow correctly?") exceeded the apparent value. v2 (window-on-canvas) is the higher-value path.

**Where it lives:** `render/src/Clickzoom.tsx` (renderer), `test/` (synthetic validation harness with calibration grid + pixel-sampling assertions), click+cursor capture pipeline in `cmd/clicks/` and `src/cli.ts`. The CLI still records clicks and cursor for every session; v2 just doesn't use them. Switch back with `--no-compose`.

**If we revisit:** consider showing the click as a soft pulse/ring overlay on the cropped window in `WindowCompose` instead of a camera move. The capture data is already there.

## Known limits / v2.next ideas

- **Browser windows include browser chrome.** Cropping a Chrome window gets the address bar and tabs too. Future: app-specific chrome stripping (Chrome content area, Safari content area).
- **Window must stay still during recording.** Bounds are captured once at recording start. If the user drags the window mid-recording, the crop drifts. Fix: sample bounds at intervals via `windows find` in a side process, interpolate.
- **A/V sync drift over long recordings.** Fine for ≤30s clips. For longer recordings the right answer is a single Swift binary using ScreenCaptureKit + AVAudioEngine sharing one mach clock — eliminates timestamp alignment entirely.
- **Background gradient is fixed.** Should be configurable (preset palette + custom).
- **No multi-monitor, no Linux/Windows, no GUI.**

## Repo layout

```
clickzoom/
├── cmd/clicks/       Swift CGEventTap recorder
│   ├── main.swift
│   └── clicks        compiled binary (committed for convenience)
├── src/cli.ts        Bun orchestrator
├── render/           Remotion project
│   ├── src/
│   │   ├── Root.tsx
│   │   ├── Clickzoom.tsx   ← composition with zoom math
│   │   ├── index.ts
│   │   └── input.json      ← CLI overwrites this per-run
│   ├── public/source.mp4   ← CLI stages here
│   └── remotion.config.ts
└── out/              recordings and final outputs
```
