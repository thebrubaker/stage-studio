#!/usr/bin/env bun
/**
 * Generate a calibration source video: 3x3 grid of distinct solid color blocks.
 * Each block is large enough that the zoom viewport (source/ZOOM_SCALE) centered
 * anywhere inside the block produces a frame whose center pixel is unambiguously
 * that block's color — even after clampOrigin pulls a corner-block viewport back.
 *
 * Block layout (3420x2224 source, ZOOM_SCALE=2 → viewport 1710x1112):
 *   col0 (cx=570)    col1 (cx=1710)   col2 (cx=2850)
 *   row0 (cy=371)    RED              GREEN              BLUE
 *   row1 (cy=1112)   YELLOW           CYAN               MAGENTA
 *   row2 (cy=1853)   WHITE            ORANGE             PURPLE
 *
 * Verified: at scale=2, clampOrigin of (570,371) → (855,556). Block (0,0) extends
 * 0..1140 x 0..741, so (855,556) is inside it. ✓
 */
import { spawnSync } from "node:child_process";
import { writeFileSync, existsSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

const W = 3420;
const H = 2224;
const DURATION = 30; // long enough for any test scenario

export const BLOCKS: { name: string; rgb: [number, number, number]; cx: number; cy: number }[] = [
  { name: "RED",     rgb: [220, 30, 30],   cx: 570,  cy: 371 },
  { name: "GREEN",   rgb: [30, 200, 30],   cx: 1710, cy: 371 },
  { name: "BLUE",    rgb: [30, 30, 220],   cx: 2850, cy: 371 },
  { name: "YELLOW",  rgb: [230, 230, 30],  cx: 570,  cy: 1112 },
  { name: "CYAN",    rgb: [30, 220, 220],  cx: 1710, cy: 1112 },
  { name: "MAGENTA", rgb: [220, 30, 220],  cx: 2850, cy: 1112 },
  { name: "WHITE",   rgb: [240, 240, 240], cx: 570,  cy: 1853 },
  { name: "ORANGE",  rgb: [240, 140, 30],  cx: 1710, cy: 1853 },
  { name: "PURPLE",  rgb: [140, 30, 200],  cx: 2850, cy: 1853 },
];

export const SOURCE_OUT = "test/calibration-source.mp4";

export function generateSource(force = false): void {
  if (existsSync(SOURCE_OUT) && !force) {
    console.log(`[gen-source] ${SOURCE_OUT} exists (pass --force to regenerate)`);
    return;
  }

  mkdirSync(dirname(SOURCE_OUT), { recursive: true });

  // Build ffmpeg drawbox filter chain.
  const blockW = W / 3;
  const blockH = H / 3;
  const drawboxes: string[] = [];
  BLOCKS.forEach((b, i) => {
    const col = i % 3;
    const row = Math.floor(i / 3);
    const x = col * blockW;
    const y = row * blockH;
    const color = `0x${b.rgb.map(c => c.toString(16).padStart(2, "0")).join("")}`;
    drawboxes.push(`drawbox=x=${x}:y=${y}:w=${blockW}:h=${blockH}:color=${color}:t=fill`);
  });
  const filter = drawboxes.join(",");

  const args = [
    "-y",
    "-f", "lavfi",
    "-i", `color=c=black:s=${W}x${H}:d=${DURATION}:r=30`,
    "-vf", filter,
    "-c:v", "h264_videotoolbox",
    "-b:v", "8M",
    "-pix_fmt", "yuv420p",
    SOURCE_OUT,
  ];

  console.log(`[gen-source] generating ${SOURCE_OUT}…`);
  const r = spawnSync("ffmpeg", args, { stdio: "inherit" });
  if (r.status !== 0) {
    throw new Error(`ffmpeg failed with status ${r.status}`);
  }
  console.log(`[gen-source] done`);
}

if (import.meta.main) {
  generateSource(process.argv.includes("--force"));
}
