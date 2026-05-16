#!/usr/bin/env bun
// stage-studio — record screen + clicks + mic, render polished MP4 with auto-zoom on each click.
//
// Phase 2: ugly end-to-end with a small set of CLI flags. Hardcodes a few things still:
//   - output resolution 2560x1440 (matches CGEventTap point space on a 5K display)
//   - capture cursor on
//   - h264_videotoolbox encoder
//   - no display picker; uses whatever `Capture screen 0` is today

import { spawn } from "node:child_process";
import { mkdirSync, writeFileSync, readFileSync, existsSync } from "node:fs";
import { resolve, dirname, basename } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, "..");
const CLICKS_BIN = resolve(REPO_ROOT, "cmd/clicks/clicks");
const WINDOWS_BIN = resolve(REPO_ROOT, "cmd/windows/windows");
const RECORDER_BIN = resolve(REPO_ROOT, "cmd/recorder/recorder");

const FPS = 30;

// Exponential smoothing time constant for cursor → camera. Camera position lags
// cursor with a ~tau half-life; smaller tau = snappier follow, larger = floatier.
// 0.18s feels close to Screen Studio's default.
const CURSOR_SMOOTH_TAU = 0.18;

// v1.3 dwell-commit: a click only triggers a zoom event if the cursor stays
// within DWELL_RADIUS_PX of the click coord for the first DWELL_WINDOW_S
// seconds after the click. Filters out "transit clicks" — click + immediately
// move far away — which would otherwise yank the camera to a place the user
// has already left.
//
// 250 source pixels at backingScale=2 ≈ 125 logical points. About a button's
// width on macOS. Tune by observation.
const DWELL_WINDOW_S = 0.3;
const DWELL_RADIUS_PX = 250;

type Args = {
  duration: number; // seconds
  output: string;
  workDir: string;
  skipRecord: boolean; // dev shortcut: reuse last recording
  /** Window picker target. If unset, use frontmost-non-self. */
  window?: string;
  /** Specific CGWindowID to record. Preferred over --window when Claude pipes
   *  an exact id from `cmd/windows list`. Skips the fuzzy-match path entirely. */
  windowId?: number;
};

function parseArgs(argv: string[]): Args {
  const args: Args = {
    duration: 8,
    output: "out.mp4",
    workDir: resolve(REPO_ROOT, "out"),
    skipRecord: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--duration" || a === "-t") args.duration = Number(argv[++i]);
    else if (a === "--output" || a === "-o") args.output = argv[++i];
    else if (a === "--work-dir") args.workDir = resolve(argv[++i]);
    else if (a === "--skip-record") args.skipRecord = true;
    else if (a === "--window" || a === "-w") args.window = argv[++i];
    else if (a === "--window-id") args.windowId = Number(argv[++i]);
    else if (a === "-h" || a === "--help") {
      console.log(`stage-studio — record a window + render polished MP4

Usage: stage-studio [options]
  -t, --duration <s>    recording duration in seconds, or 0 for open-ended
                        (stops on SIGTERM; default 8). Open-ended recordings
                        cap at 5 minutes as a safety.
  -o, --output <path>   final MP4 path (default ./out.mp4)
      --work-dir <p>    where to put intermediate artifacts (default ./out)
      --skip-record     reuse existing recording in work-dir (re-render only)
  -w, --window <pat>    target window pattern (case-insensitive substring of
                        app+title; default: frontmost non-terminal window)
      --window-id <N>   target specific CGWindowID (numeric). Use this when
                        you have an exact id from \`cmd/windows list\`.
  -h, --help            this help

  When --duration 0 is used, the recorder PID is printed to stdout as:
    [stage-studio] recorder PID: <pid>
  Send SIGTERM to that PID to stop the recording cleanly.
`);
      process.exit(0);
    } else {
      console.error(`unknown arg: ${a}`);
      process.exit(1);
    }
  }
  return args;
}

type WindowBounds = {
  title: string;
  app: string;
  pid: number;
  windowId: number;
  /** Bounds in screen POINTS — caller converts to source pixels by multiplying by backingScale. */
  bounds: { x: number; y: number; w: number; h: number };
};

async function detectWindow(opts: { pattern?: string; windowId?: number }): Promise<WindowBounds> {
  if (!existsSync(WINDOWS_BIN)) {
    throw new Error(`windows binary missing at ${WINDOWS_BIN} — run \`pnpm run build:windows\``);
  }
  // Priority: --window-id (exact, unambiguous) > --window (pattern) > frontmost.
  let subcmd: string[];
  if (opts.windowId !== undefined) {
    // No `windows by-id` subcommand yet — we list and filter. Cheap; macOS
    // returns the full window list synchronously.
    return new Promise((resolveBounds, reject) => {
      const proc = spawn(WINDOWS_BIN, ["list"], { stdio: ["ignore", "pipe", "pipe"] });
      let stdout = "";
      let stderr = "";
      proc.stdout.on("data", (d) => (stdout += d.toString()));
      proc.stderr.on("data", (d) => (stderr += d.toString()));
      proc.on("close", (code) => {
        if (code !== 0) return reject(new Error(`windows list failed (${code}): ${stderr.trim()}`));
        try {
          const all = JSON.parse(stdout) as WindowBounds[];
          const hit = all.find((w) => w.windowId === opts.windowId);
          if (!hit) return reject(new Error(`window-id ${opts.windowId} not found in ${all.length} listed windows`));
          resolveBounds(hit);
        } catch (e) {
          reject(new Error(`failed to parse windows JSON: ${(e as Error).message}`));
        }
      });
    });
  } else {
    subcmd = opts.pattern ? ["find", opts.pattern] : ["frontmost"];
  }
  return new Promise((resolveBounds, reject) => {
    const proc = spawn(WINDOWS_BIN, subcmd, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    proc.stdout.on("data", (d) => (stdout += d.toString()));
    proc.stderr.on("data", (d) => (stderr += d.toString()));
    proc.on("close", (code) => {
      if (code !== 0) return reject(new Error(`windows ${subcmd.join(" ")} failed (${code}): ${stderr.trim()}`));
      try {
        const w = JSON.parse(stdout) as WindowBounds;
        resolveBounds(w);
      } catch (e) {
        reject(new Error(`failed to parse windows JSON: ${(e as Error).message}\n${stdout}`));
      }
    });
  });
}

type Click = { t: number; x: number; y: number; button: string };
type CursorSample = { t: number; x: number; y: number };

type InputEvent =
  | { kind: "meta"; pointWidth: number; pointHeight: number; backingScale: number }
  | { kind: "click"; epoch: number; x: number; y: number; button: string }
  | { kind: "move"; epoch: number; x: number; y: number };

type DisplayMeta = { pointWidth: number; pointHeight: number; backingScale: number };

function loadInputTrack(
  path: string,
  t0Epoch: number,
  durationSeconds: number,
  dpr: number,
): { clicks: Click[]; cursor: CursorSample[]; meta: DisplayMeta | null } {
  const raw = readFileSync(path, "utf8");
  const clicks: Click[] = [];
  const cursor: CursorSample[] = [];
  let meta: DisplayMeta | null = null;

  for (const line of raw.split("\n")) {
    if (!line.trim()) continue;
    let e: InputEvent;
    try {
      e = JSON.parse(line) as InputEvent;
    } catch {
      continue;
    }
    if (e.kind === "meta") {
      meta = { pointWidth: e.pointWidth, pointHeight: e.pointHeight, backingScale: e.backingScale };
      continue;
    }
    const t = e.epoch - t0Epoch;
    if (t < 0) continue; // pre-roll, ignore
    if (t > durationSeconds + 0.5) continue; // tail noise after ffmpeg stopped
    if (e.kind === "click") clicks.push({ t, x: e.x * dpr, y: e.y * dpr, button: e.button });
    else cursor.push({ t, x: e.x * dpr, y: e.y * dpr });
  }
  cursor.sort((a, b) => a.t - b.t);
  return { clicks, cursor, meta };
}

/**
 * Exponential smoothing with continuous-time correction (samples aren't uniform).
 * Per-sample: alpha = 1 - exp(-dt / tau). Output preserves the input timeline.
 */
function smoothCursor(samples: CursorSample[], tau: number): CursorSample[] {
  if (samples.length <= 1) return samples;
  const out: CursorSample[] = [samples[0]];
  for (let i = 1; i < samples.length; i++) {
    const dt = samples[i].t - samples[i - 1].t;
    const alpha = 1 - Math.exp(-dt / tau);
    const prev = out[i - 1];
    out.push({
      t: samples[i].t,
      x: prev.x + (samples[i].x - prev.x) * alpha,
      y: prev.y + (samples[i].y - prev.y) * alpha,
    });
  }
  return out;
}

/**
 * Dwell-commit: keep only clicks where the user's cursor lingered near the
 * click coord for DWELL_WINDOW_S seconds after the click. Drops transit clicks
 * (click + immediately moved far away).
 *
 * Note we deliberately use the SMOOTHED cursor stream as the dwell oracle —
 * this filter runs after smoothCursor. The smoothed signal is also what the
 * eye sees, so dwell-from-smoothed matches the user's perceived "did they
 * stay there?" question.
 */
export function commitClicks(clicks: Click[], cursor: CursorSample[]): Click[] {
  return clicks.filter(c => {
    const tEnd = c.t + DWELL_WINDOW_S;
    let maxDist = 0;
    let sawSample = false;
    for (const s of cursor) {
      if (s.t < c.t) continue;
      if (s.t > tEnd) break;
      sawSample = true;
      const dx = s.x - c.x;
      const dy = s.y - c.y;
      const d = Math.sqrt(dx * dx + dy * dy);
      if (d > maxDist) maxDist = d;
    }
    // No cursor samples in the window (cursor was idle) → user definitely
    // dwelled → commit.
    if (!sawSample) return true;
    return maxDist <= DWELL_RADIUS_PX;
  });
}

async function record(args: Args, windowID: number, outputPath: string, workDir: string) {
  // v3: recorder owns the whole pipeline — captures, composites onto a styled
  // background via Core Image, and outputs the final H.264 MP4 directly. No
  // post-recording stage needed.
  const clicksPath = resolve(workDir, "clicks.jsonl");
  mkdirSync(workDir, { recursive: true });

  // Spawn click recorder first — its first stdout line is the display meta breadcrumb
  // (point dims + backing scale), which we need afterward to translate click coords.
  console.error(`[stage-studio] starting input recorder…`);
  const clicksProc = spawn(CLICKS_BIN, [], { stdio: ["ignore", "pipe", "pipe"] });
  writeFileSync(clicksPath, "");
  const clicksOut = Bun.file(clicksPath).writer();
  clicksProc.stdout.on("data", (d) => clicksOut.write(d));
  clicksProc.stderr.on("data", (d) => process.stderr.write(`[clicks] ${d}`));
  // Wait briefly for the meta + ready breadcrumb to land.
  await new Promise((r) => setTimeout(r, 400));

  spawn("afplay", ["/System/Library/Sounds/Tink.aiff"], { stdio: "ignore" });
  console.error(`\n[stage-studio] >>> RECORDING ${args.duration}s <<<\n`);
  // Lock t0 right before recorder spawn. SCK first-frame latency is typically
  // smaller than ffmpeg's (~100-200ms vs ~200-500ms) but still nonzero.
  const t0Epoch = Date.now() / 1000;

  // Recorder writes the FINAL styled MP4 directly to outputPath. Capture +
  // compose + encode all happen inside one Swift process using SCK + Core
  // Image + AVAssetWriter. No intermediate file, no Remotion pass.
  //
  // Default background: the Big Sur Color Day wallpaper, downloaded once and
  // checked into the repo at assets/. The recorder loads it at init and
  // scale-to-fills the 1920x1080 canvas. Override via RECORDER_BG_IMAGE.
  const defaultBg = resolve(REPO_ROOT, "assets/big-sur-graphic.jpg");
  const recorderProc = spawn(
    RECORDER_BIN,
    [String(windowID), String(args.duration), outputPath],
    {
      stdio: ["ignore", "inherit", "inherit"],
      env: {
        ...process.env,
        RECORDER_BG_IMAGE: process.env.RECORDER_BG_IMAGE ?? (existsSync(defaultBg) ? defaultBg : ""),
      },
    },
  );
  // Surface the recorder's PID so Claude (or any external controller) can
  // SIGTERM it when the user says "stop". Print in a machine-parseable form.
  if (recorderProc.pid !== undefined) {
    console.log(`[stage-studio] recorder PID: ${recorderProc.pid}`);
  }
  // Forward our own SIGTERM/SIGINT to the recorder so foreground Ctrl-C and
  // sigterm-to-cli both work as a clean stop.
  const forwardSignal = (sig: NodeJS.Signals) => {
    if (recorderProc.pid !== undefined && !recorderProc.killed) {
      recorderProc.kill(sig);
    }
  };
  process.on("SIGTERM", () => forwardSignal("SIGTERM"));
  process.on("SIGINT", () => forwardSignal("SIGINT"));
  await new Promise<void>((r, j) => {
    recorderProc.on("close", (code) => (code === 0 ? r() : j(new Error(`recorder exited ${code}`))));
  });

  spawn("afplay", ["/System/Library/Sounds/Pop.aiff"], { stdio: "ignore" });

  clicksProc.kill("SIGTERM");
  await new Promise((r) => setTimeout(r, 100));
  await clicksOut.end();

  return { clicksPath, t0Epoch };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));

  if (!existsSync(CLICKS_BIN)) {
    console.error(`[stage-studio] clicks binary missing at ${CLICKS_BIN} — run \`pnpm run build:clicks\``);
    process.exit(1);
  }
  if (!existsSync(RECORDER_BIN)) {
    console.error(`[stage-studio] recorder binary missing at ${RECORDER_BIN} — run \`pnpm run build:recorder\``);
    process.exit(1);
  }
  if (!existsSync(WINDOWS_BIN)) {
    console.error(`[stage-studio] windows binary missing at ${WINDOWS_BIN} — run \`pnpm run build:windows\``);
    process.exit(1);
  }

  const workDir = args.workDir;
  const outputPath = resolve(args.output);

  // v3: detect the target window BEFORE recording. SCK records ONLY that window's
  // content (occlusion-immune); recorder composites onto a styled background
  // and writes the final MP4 directly. No post-recording stage.
  const windowInfo = await detectWindow({ pattern: args.window, windowId: args.windowId });
  console.error(`[stage-studio] target window: "${windowInfo.title}" (${windowInfo.app}) ${windowInfo.bounds.w}x${windowInfo.bounds.h} @ (${windowInfo.bounds.x}, ${windowInfo.bounds.y})`);

  if (args.skipRecord) {
    console.error(`[stage-studio] --skip-record: no longer supported in v3 (no intermediate stage to reuse). Re-record.`);
    process.exit(1);
  }

  const { clicksPath, t0Epoch } = await record(args, windowInfo.windowId, outputPath, workDir);
  writeFileSync(resolve(workDir, "meta.json"), JSON.stringify({ t0Epoch, windowInfo }, null, 2));

  // Load click/cursor data for diagnostics (and future overlay features).
  const probe = loadInputTrack(clicksPath, t0Epoch, args.duration, /*placeholder*/ 1);
  const dpr = probe.meta?.backingScale ?? 2;
  const { clicks, cursor } = loadInputTrack(clicksPath, t0Epoch, args.duration, dpr);
  const smoothed = smoothCursor(cursor, CURSOR_SMOOTH_TAU);
  const committed = commitClicks(clicks, smoothed);

  console.error(`[stage-studio] ${committed.length}/${clicks.length} click(s) committed, ${cursor.length} cursor sample(s) (overlay TBD)`);
  console.error(`[stage-studio] wrote ${outputPath}`);
}

main().catch((err) => {
  console.error(`[stage-studio] error: ${err.message}`);
  process.exit(1);
});
