#!/usr/bin/env bun
/**
 * Self-validation harness for the Clickzoom composition.
 *
 * Approach: render against the synthetic calibration grid (test/gen-source.ts)
 * with deterministic click+cursor scenarios. For each scenario, extract the
 * frame at peak zoom (click + HOLD/2) and sample the center RGB. Classify which
 * grid block we landed on and compare to expected.
 *
 * Wins:
 *  - No physical recording needed → 0 user attention required to iterate.
 *  - Deterministic input → reproducible failures.
 *  - Pixel-level pass/fail → no "looks right" eyeballing.
 */
import { spawnSync, spawn } from "node:child_process";
import { writeFileSync, copyFileSync, mkdirSync, existsSync } from "node:fs";
import { BLOCKS, SOURCE_OUT as SOURCE_MP4, generateSource } from "./gen-source";

const RENDER_PUBLIC = "render/public/source.mp4";
const INPUT_JSON = "render/src/input.json";
const RENDER_OUT = "test/out/render.mp4";
const W = 3420;
const H = 2224;
const FPS = 30;

// Must match Clickzoom.tsx (v1.3)
const ZOOM_SCALE = 1.5;
const ANTICIPATE = 0.5;
const HOLD = 0.9;
const RELEASE = 0.6;

// Must match cli.ts dwell-commit constants
const DWELL_WINDOW_S = 0.3;
const DWELL_RADIUS_PX = 250;

/** Mirror of cli.ts commitClicks — apply dwell-commit filter on synthetic clicks. */
function commitClicks(clicks: { t: number; x: number; y: number }[], cursor: { t: number; x: number; y: number }[]) {
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
    if (!sawSample) return true;
    return maxDist <= DWELL_RADIUS_PX;
  });
}

/** Where in OUTPUT pixel coords does the click coord (source pixel) land at peak zoom?
 *  Mirror of computeTranslate: source(x,y) → output(S*x - tx, S*y - ty). */
function expectedOutputLocation(cx: number, cy: number, w: number, h: number) {
  const rawTx = ZOOM_SCALE * cx - w / 2;
  const rawTy = ZOOM_SCALE * cy - h / 2;
  const maxTx = w * (ZOOM_SCALE - 1);
  const maxTy = h * (ZOOM_SCALE - 1);
  const tx = Math.max(0, Math.min(maxTx, rawTx));
  const ty = Math.max(0, Math.min(maxTy, rawTy));
  return { ox: ZOOM_SCALE * cx - tx, oy: ZOOM_SCALE * cy - ty };
}

type Case = {
  id: string;
  /** Click time (seconds in render). */
  clickT: number;
  /** Block we expect to see at the click coord's expected output location at peak zoom.
   *  For dwell-rejected clicks, expect the source's same block (no zoom, full source visible). */
  expect: string;
  /** Block to click on (used to derive x,y). */
  clickOn: string;
  /** Cursor scenario at click time. */
  cursor: "click" | { kind: "static"; block: string } | { kind: "drift"; fromBlock: string; toBlock: string; durationS: number };
  /** If true, expect the click to be dropped by dwell-commit (no zoom event). */
  expectDropped?: boolean;
};

const blockByName = (name: string) => {
  const b = BLOCKS.find(b => b.name === name);
  if (!b) throw new Error(`unknown block: ${name}`);
  return b;
};

const CASES: Case[] = [
  // Baseline: click on each block, cursor co-located with click. Zoom commits,
  // sample at click's expected output location → should see the clicked block.
  { id: "A-red-static",     clickT: 2,  clickOn: "RED",     expect: "RED",     cursor: "click" },
  { id: "B-cyan-static",    clickT: 6,  clickOn: "CYAN",    expect: "CYAN",    cursor: "click" },
  { id: "C-purple-static",  clickT: 10, clickOn: "PURPLE",  expect: "PURPLE",  cursor: "click" },

  // v1.2 lag bug regression check: cursor parked at CYAN, click on RED.
  // Dwell-commit drops this click (cursor not near click during dwell window),
  // so no zoom event. Source unmodified, click coord (570,371) still RED.
  // expectDropped → assertion changes to "click sample location == clickOn block".
  { id: "D-lag-bug-dropped", clickT: 14, clickOn: "RED",     expect: "RED",     cursor: { kind: "static", block: "CYAN" }, expectDropped: true },

  // Transit click: click on CYAN but cursor drifts far away during dwell window.
  // Dwell-commit drops it. No zoom event. Sample at click coord = un-zoomed CYAN.
  { id: "F-transit-drop",   clickT: 18, clickOn: "CYAN",    expect: "CYAN",    cursor: { kind: "drift", fromBlock: "CYAN", toBlock: "PURPLE", durationS: 0.4 }, expectDropped: true },
];

const DURATION = 22; // covers clicks up to t=18 + HOLD + RELEASE

function buildInputJSON(cases: Case[]) {
  const rawClicks = cases.map(c => {
    const b = blockByName(c.clickOn);
    return { t: c.clickT, x: b.cx, y: b.cy, button: "left" };
  });

  // Build cursor track from cases. Each case contributes a few samples.
  const cursor: { t: number; x: number; y: number }[] = [];
  for (const c of cases) {
    if (c.cursor === "click") {
      const b = blockByName(c.clickOn);
      // Park cursor at click coord well before click time. Single sample is enough
      // because cursorAt clamps to first/last for out-of-range times.
      cursor.push({ t: c.clickT - 1.0, x: b.cx, y: b.cy });
      cursor.push({ t: c.clickT + 0.1, x: b.cx, y: b.cy });
    } else if (c.cursor.kind === "static") {
      const b = blockByName(c.cursor.block);
      cursor.push({ t: c.clickT - 1.0, x: b.cx, y: b.cy });
      cursor.push({ t: c.clickT + 0.1, x: b.cx, y: b.cy });
    } else if (c.cursor.kind === "drift") {
      const a = blockByName(c.cursor.fromBlock);
      const b = blockByName(c.cursor.toBlock);
      // Park before drift
      cursor.push({ t: c.clickT - 1.0, x: a.cx, y: a.cy });
      // Dense 60Hz samples along the drift, mirroring the real Swift recorder.
      // This is what makes dwell-commit see the motion within its window.
      const steps = Math.ceil(c.cursor.durationS * 60);
      for (let i = 0; i <= steps; i++) {
        const u = i / steps;
        cursor.push({
          t: c.clickT + u * c.cursor.durationS,
          x: a.cx + (b.cx - a.cx) * u,
          y: a.cy + (b.cy - a.cy) * u,
        });
      }
    }
  }
  cursor.sort((a, b) => a.t - b.t);

  // Apply dwell-commit filter (mirrors cli.ts behavior so the harness exercises
  // the same logic the real pipeline does).
  const clicks = commitClicks(rawClicks, cursor);

  return {
    rawClicks,
    input: {
      videoSrc: "source.mp4",
      width: W,
      height: H,
      durationSeconds: DURATION,
      fps: FPS,
      clicks,
      cursor,
    },
  };
}

function stageSource() {
  if (!existsSync(SOURCE_MP4)) {
    throw new Error(`${SOURCE_MP4} missing — run test/gen-source.ts first`);
  }
  mkdirSync("render/public", { recursive: true });
  copyFileSync(SOURCE_MP4, RENDER_PUBLIC);
}

function render() {
  mkdirSync("test/out", { recursive: true });
  console.log(`[test] rendering ${RENDER_OUT}…`);
  const r = spawnSync(
    "pnpm",
    ["exec", "remotion", "render", "src/index.ts", "Clickzoom", `../${RENDER_OUT}`, "--props=src/input.json"],
    { cwd: "render", stdio: "inherit" }
  );
  if (r.status !== 0) throw new Error(`remotion render failed: ${r.status}`);
}

/**
 * Sample average RGB of a 20x20 region centered at (ox, oy) in the rendered output,
 * at time t. Use post-input seek for accurate frame selection.
 */
async function sampleAt(t: number, ox: number, oy: number): Promise<[number, number, number]> {
  // ffmpeg's crop expects x,y to be top-left of crop region.
  const cropX = Math.max(0, Math.round(ox - 10));
  const cropY = Math.max(0, Math.round(oy - 10));
  const args = [
    "-i", RENDER_OUT,
    "-ss", t.toFixed(3),
    "-frames:v", "1",
    "-vf", `crop=20:20:${cropX}:${cropY},format=rgb24`,
    "-f", "rawvideo",
    "-",
  ];
  const proc = spawn("ffmpeg", args, { stdio: ["ignore", "pipe", "ignore"] });
  const chunks: Buffer[] = [];
  for await (const ch of proc.stdout) chunks.push(ch as Buffer);
  const buf = Buffer.concat(chunks);
  if (buf.length < 1200) throw new Error(`unexpected pixel buffer length ${buf.length}`);
  let r = 0, g = 0, bl = 0;
  const px = buf.length / 3;
  for (let i = 0; i < buf.length; i += 3) {
    r += buf[i];
    g += buf[i + 1];
    bl += buf[i + 2];
  }
  return [r / px, g / px, bl / px];
}

function classifyColor(rgb: [number, number, number]): { name: string; dist: number } {
  let best = { name: "?", dist: Infinity };
  for (const b of BLOCKS) {
    const dr = b.rgb[0] - rgb[0];
    const dg = b.rgb[1] - rgb[1];
    const db = b.rgb[2] - rgb[2];
    const d = Math.sqrt(dr * dr + dg * dg + db * db);
    if (d < best.dist) best = { name: b.name, dist: d };
  }
  return best;
}

async function main() {
  generateSource(false);

  console.log(`[test] building input.json with ${CASES.length} cases`);
  const { rawClicks, input } = buildInputJSON(CASES);
  writeFileSync(INPUT_JSON, JSON.stringify(input, null, 2));

  // Verify dwell-commit expectations match what the harness filter actually did.
  console.log(`[test] dwell-commit kept ${input.clicks.length}/${rawClicks.length} clicks`);
  const committedTimes = new Set(input.clicks.map(c => c.t));

  stageSource();
  render();

  console.log(`\n[test] checking results:\n`);
  let passed = 0;
  let failed = 0;
  for (const c of CASES) {
    const peakT = c.clickT + HOLD / 2;
    const block = blockByName(c.clickOn);
    const wasCommitted = committedTimes.has(c.clickT);
    const shouldDrop = c.expectDropped === true;

    // Dwell-commit assertion: did filter behave as expected?
    if (shouldDrop && wasCommitted) {
      failed++;
      console.log(`✗ ${c.id.padEnd(22)} dwell-commit expected DROP but click was committed`);
      continue;
    }
    if (!shouldDrop && !wasCommitted) {
      failed++;
      console.log(`✗ ${c.id.padEnd(22)} dwell-commit expected COMMIT but click was dropped`);
      continue;
    }

    // Sample location: at click's expected output position (zoomed) or at the
    // un-zoomed source pixel (no-zoom case for dropped clicks).
    let ox: number, oy: number;
    if (wasCommitted) {
      const loc = expectedOutputLocation(block.cx, block.cy, W, H);
      ox = loc.ox; oy = loc.oy;
    } else {
      ox = block.cx; oy = block.cy;
    }
    const rgb = await sampleAt(peakT, ox, oy);
    const got = classifyColor(rgb);
    const ok = got.name === c.expect;
    if (ok) passed++; else failed++;
    const mark = ok ? "✓" : "✗";
    const tag = wasCommitted ? "zoomed" : "no-zoom";
    console.log(`${mark} ${c.id.padEnd(22)} ${tag.padEnd(7)} expect=${c.expect.padEnd(7)} got=${got.name.padEnd(7)} (rgb=${rgb.map(v => Math.round(v)).join(",")}, dist=${got.dist.toFixed(1)}) sample=(${Math.round(ox)},${Math.round(oy)}) t=${peakT.toFixed(2)}s`);
  }

  console.log(`\n[test] ${passed}/${CASES.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
}

main().catch(err => { console.error(err); process.exit(1); });
