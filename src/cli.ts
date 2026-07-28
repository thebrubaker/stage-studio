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
import { connect } from "node:net";
import { homedir } from "node:os";
import { resolve, dirname, basename } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, "..");
const CLICKS_BIN = resolve(REPO_ROOT, "cmd/clicks/clicks");
const WINDOWS_BIN = resolve(REPO_ROOT, "cmd/windows/windows");
const RECORDER_BIN = resolve(REPO_ROOT, "cmd/recorder/recorder");

const FPS = 30;

// ---------------------------------------------------------------------------
// Control surface — talking to the running Stage Studio app (DIG-793)
//
// Recording routes through the app by default so that EVERY recording, however
// it was started, puts the pill on screen. That visibility is the point: an
// agent-initiated capture the user can't see and can't kill is not something
// that should be possible.
//
// The old direct-spawn path still exists behind --headless for contexts with no
// GUI session to talk to.
// ---------------------------------------------------------------------------

const APP_PATH = "/Applications/Stage Studio.app";
const CONTROL_SOCKET = resolve(
  homedir(),
  "Library/Application Support/Stage Studio/control.sock",
);

type ControlResponse = {
  ok: boolean;
  state?: string;
  output?: string;
  duration?: number;
  cancelled?: boolean;
  error?: string;
  message?: string;
  [key: string]: unknown;
};

/** One request, one response, connection closes. */
function control(payload: Record<string, unknown>, timeoutMs = 15 * 60_000): Promise<ControlResponse> {
  return new Promise((resolveP, reject) => {
    const sock = connect({ path: CONTROL_SOCKET });
    let buf = "";
    const timer = setTimeout(() => {
      sock.destroy();
      reject(new Error(`control timeout after ${timeoutMs}ms`));
    }, timeoutMs);
    sock.on("connect", () => sock.write(JSON.stringify(payload) + "\n"));
    sock.on("data", (d) => (buf += d.toString()));
    sock.on("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });
    sock.on("close", () => {
      clearTimeout(timer);
      const text = buf.trim();
      if (!text) return reject(new Error("control closed without a response"));
      try {
        resolveP(JSON.parse(text) as ControlResponse);
      } catch {
        reject(new Error(`unparseable control response: ${text}`));
      }
    });
  });
}

async function appIsUp(): Promise<boolean> {
  if (!existsSync(CONTROL_SOCKET)) return false;
  try {
    const res = await control({ command: "ping" }, 2000);
    return res.ok === true;
  } catch {
    // A socket file left behind by a crashed instance looks present but refuses
    // connections — treat that as "not running" rather than a hard failure.
    return false;
  }
}

/** Bring the app up if it isn't already, and wait until it answers. */
async function ensureApp(): Promise<void> {
  if (await appIsUp()) return;
  if (!existsSync(APP_PATH)) {
    throw new Error(
      `Stage Studio isn't installed at ${APP_PATH}. Build and install it with ` +
        `\`pnpm run build:app\`, or use --headless to bypass the app entirely.`,
    );
  }
  console.error(`[stage-studio] launching ${basename(APP_PATH)}…`);
  spawn("open", ["-a", APP_PATH], { stdio: "ignore", detached: true }).unref();

  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 300));
    if (await appIsUp()) return;
  }
  throw new Error("Stage Studio did not come up within 15s");
}

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
  /** Subcommand short-circuit: print all on-screen windows as JSON and exit.
   *  Intended for the /stage skill — gives it a window picker without depending
   *  on the bundled cmd/windows binary path. */
  listWindows: boolean;
  /** Bypass the app and spawn the recorder directly (the pre-DIG-793 path).
   *  For contexts with no GUI session to show a pill in. */
  headless: boolean;
  /** Who the pill says started this. */
  label: string;
  /** `agent` (default for CLI-driven recordings) or `human`. */
  source: "agent" | "human";
  /** Control subcommand, if the invocation was one. */
  controlCommand?: "stop" | "cancel" | "status";
};

function parseArgs(argv: string[]): Args {
  const args: Args = {
    duration: 8,
    output: "out.mp4",
    workDir: resolve(REPO_ROOT, "out"),
    skipRecord: false,
    listWindows: false,
    headless: false,
    label: "Claude",
    source: "agent",
  };
  // Control subcommands: `stage-studio stop|cancel|status`.
  if (argv[0] === "stop" || argv[0] === "cancel" || argv[0] === "status") {
    args.controlCommand = argv[0];
    return args;
  }
  // Accept `stage-studio list-windows` as a bare subcommand (no leading dashes).
  // Strictly positional: it has to be the first arg. Anything else falls through
  // to the regular flag parser, including `--list-windows` for symmetry.
  if (argv[0] === "list-windows" || argv[0] === "--list-windows") {
    args.listWindows = true;
    return args;
  }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--duration" || a === "-t") args.duration = Number(argv[++i]);
    else if (a === "--output" || a === "-o") args.output = argv[++i];
    else if (a === "--work-dir") args.workDir = resolve(argv[++i]);
    else if (a === "--skip-record") args.skipRecord = true;
    else if (a === "--window" || a === "-w") args.window = argv[++i];
    else if (a === "--window-id") args.windowId = Number(argv[++i]);
    else if (a === "--headless") args.headless = true;
    else if (a === "--label") args.label = argv[++i];
    else if (a === "--source") args.source = argv[++i] === "human" ? "human" : "agent";
    else if (a === "-h" || a === "--help") {
      console.log(`stage-studio — record a window + render polished MP4

Recordings route through the Stage Studio app by default, so every recording
shows the on-screen pill and can be stopped by hand (Esc / click / ⌥⌘R).

Usage:
  stage-studio [options]              start a recording (default)
  stage-studio stop                   stop the running recording, print the file
  stage-studio cancel                 abort and delete the partial file
  stage-studio status                 print what the app is doing, as JSON
  stage-studio list-windows           print on-screen windows as JSON and exit

Recording options:
  -t, --duration <s>    recording duration in seconds, or 0 for open-ended
                        (stops on SIGTERM; default 8). Open-ended recordings
                        cap at 5 minutes as a safety.
  -o, --output <path>   final MP4 path (default ./out.mp4)
      --work-dir <p>    where to put intermediate artifacts (default ./out)
      --skip-record     reuse existing recording in work-dir (re-render only)
  -w, --window <pat>    target window pattern (case-insensitive substring of
                        app+title; default: frontmost non-terminal window)
      --window-id <N>   target specific CGWindowID (numeric). Use this when
                        you have an exact id from \`stage-studio list-windows\`.
      --label <name>    who the pill credits for the recording (default Claude)
      --source <who>    agent (default) or human — picks the pill's treatment
      --headless        bypass the app: spawn the recorder directly, no pill.
                        Only for contexts with no GUI session.
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

/**
 * Drive a recording through the running app. Returns when the outcome is real:
 * `start` doesn't resolve until the countdown has elapsed, so a user who hits
 * Esc during it produces a cancelled result rather than a false "recording".
 */
async function recordViaApp(args: Args) {
  await ensureApp();

  const windowId = args.windowId ?? (await detectWindow({ pattern: args.window })).windowId;
  const started = await control({
    command: "start",
    windowId,
    output: resolve(args.output),
    source: args.source,
    label: args.label,
  });

  if (!started.ok) {
    if (started.error === "busy") {
      // Never queue, never preempt — whoever owns the pill owns the machine.
      console.error(
        `[stage-studio] busy: a ${started.state} session is already running. ` +
          `Stop it first (\`stage-studio stop\`, Esc, or ⌥⌘R).`,
      );
      process.exit(3);
    }
    if (started.cancelled) {
      console.error(`[stage-studio] cancelled during the countdown — nothing recorded.`);
      process.exit(4);
    }
    console.error(`[stage-studio] could not start: ${started.error ?? "unknown"}${started.message ? ` — ${started.message}` : ""}`);
    process.exit(1);
  }

  console.log(`[stage-studio] recording → ${started.output}`);

  if (args.duration <= 0) {
    // Open-ended: hand control back. Stop with `stage-studio stop`, or by hand.
    console.error(`[stage-studio] open-ended — stop with \`stage-studio stop\` (or Esc / ⌥⌘R).`);
    return;
  }

  await new Promise((r) => setTimeout(r, args.duration * 1000));
  const stopped = await control({ command: "stop" });
  reportStop(stopped);
}

function reportStop(res: ControlResponse) {
  if (res.cancelled) {
    // The user's physical controls outrank the caller's request, and the caller
    // is told plainly rather than being handed a missing file to puzzle over.
    console.error(`[stage-studio] the recording was stopped by hand — no file written.`);
    process.exit(4);
  }
  if (!res.ok) {
    console.error(`[stage-studio] stop failed: ${res.error ?? "unknown"}`);
    process.exit(1);
  }
  const seconds = res.duration ? ` (${res.duration.toFixed(1)}s)` : "";
  console.log(`[stage-studio] saved ${res.output}${seconds}`);
}

async function runControlCommand(command: "stop" | "cancel" | "status") {
  if (!(await appIsUp())) {
    console.error(`[stage-studio] Stage Studio isn't running — nothing to ${command}.`);
    process.exit(2);
  }
  const res = await control({ command });
  if (command === "status") {
    console.log(JSON.stringify(res, null, 2));
    return;
  }
  if (command === "cancel") {
    console.log(`[stage-studio] cancelled${res.ok ? "" : ` (${res.error})`}`);
    return;
  }
  reportStop(res);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));

  if (args.controlCommand) {
    await runControlCommand(args.controlCommand);
    return;
  }

  if (args.listWindows) {
    // Thin pass-through to the windows binary. Inherits stdio so callers get
    // the raw JSON array on stdout and any errors on stderr.
    if (!existsSync(WINDOWS_BIN)) {
      console.error(`[stage-studio] windows binary missing at ${WINDOWS_BIN} — run \`pnpm run build:windows\``);
      process.exit(1);
    }
    const proc = spawn(WINDOWS_BIN, ["list"], { stdio: "inherit" });
    proc.on("close", (code) => process.exit(code ?? 1));
    return;
  }

  // The default path: drive the app, so the recording is visible and killable.
  if (!args.headless) {
    await recordViaApp(args);
    return;
  }

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
