import { AbsoluteFill, OffthreadVideo, useCurrentFrame, useVideoConfig, Easing, interpolate, staticFile } from "remotion";

export type Click = {
  /** Seconds from video t=0. */
  t: number;
  /** Pixel coordinates in video space (= macOS points when capture is scaled to point resolution). */
  x: number;
  y: number;
  button: string;
};

export type CursorSample = { t: number; x: number; y: number };

export type ClickzoomProps = {
  videoSrc: string;
  width: number;
  height: number;
  clicks: Click[];
  cursor: CursorSample[];
};

// v1.3: zoom is a subtle attention-pointer, not a dramatic magnifier. Camera
// anchors at click coord during HOLD — no cursor tracking. Click-filtering
// happens upstream (cli.ts dwell-commit), so by the time we get here every
// click is a committed zoom event.
const ZOOM_SCALE = 1.5;
const ANTICIPATE = 0.5; // seconds before click to start zoom-in
const HOLD = 0.9;       // seconds at full zoom after click
const RELEASE = 0.6;    // seconds to zoom back out

const easing = Easing.bezier(0.4, 0, 0.2, 1);

/**
 * Returns the active click whose zoom window contains tNow, preferring the latest.
 * Window: [t_click - ANTICIPATE, t_click + HOLD + RELEASE].
 */
function activeClick(clicks: Click[], tNow: number): Click | null {
  for (let i = clicks.length - 1; i >= 0; i--) {
    const c = clicks[i];
    if (tNow >= c.t - ANTICIPATE && tNow <= c.t + HOLD + RELEASE) {
      return c;
    }
  }
  return null;
}

/**
 * Cursor position at time t, interpolated linearly between adjacent samples.
 * Falls back to the click position if no cursor samples bracket t (e.g. cursor
 * hasn't moved since spawn) — that way we never have to invent a position.
 */
function cursorAt(cursor: CursorSample[], t: number, fallback: { x: number; y: number }): { x: number; y: number } {
  if (cursor.length === 0) return fallback;
  if (t <= cursor[0].t) return { x: cursor[0].x, y: cursor[0].y };
  if (t >= cursor[cursor.length - 1].t) {
    const last = cursor[cursor.length - 1];
    return { x: last.x, y: last.y };
  }
  // Binary search for the bracketing pair.
  let lo = 0, hi = cursor.length - 1;
  while (hi - lo > 1) {
    const mid = (lo + hi) >> 1;
    if (cursor[mid].t <= t) lo = mid;
    else hi = mid;
  }
  const a = cursor[lo];
  const b = cursor[hi];
  const u = (t - a.t) / (b.t - a.t);
  return { x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u };
}

/**
 * Compute translate offsets (tx, ty) and clamp them so the scaled video fills
 * the output frame and the visible window stays inside the source.
 *
 * Transform model: `translate(-tx, -ty) scale(S)` with transform-origin (0, 0).
 * After this, source point (x, y) lands at output (S*x - tx, S*y - ty).
 *
 * To place source target (px, py) at output center (W/2, H/2):
 *   tx = S*px - W/2
 *   ty = S*py - H/2
 *
 * Clamping (visible window stays inside source):
 *   tx ∈ [0, W * (S - 1)]
 *   ty ∈ [0, H * (S - 1)]
 *
 * When target is near an edge, clamping pulls the camera back; the click point
 * may end up off-center but never out of frame.
 */
function computeTranslate(targetX: number, targetY: number, w: number, h: number, scale: number): { tx: number; ty: number } {
  const rawTx = scale * targetX - w / 2;
  const rawTy = scale * targetY - h / 2;
  const maxTx = w * (scale - 1);
  const maxTy = h * (scale - 1);
  return {
    tx: Math.max(0, Math.min(maxTx, rawTx)),
    ty: Math.max(0, Math.min(maxTy, rawTy)),
  };
}

export const Clickzoom: React.FC<ClickzoomProps> = ({ videoSrc, width, height, clicks, cursor }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const t = frame / fps;

  const c = activeClick(clicks, t);

  let scale = 1;
  let tx = 0;
  let ty = 0;

  if (c) {
    // Scale curve: 1 → ZOOM (over ANTICIPATE) → hold ZOOM (over HOLD) → ZOOM → 1 (over RELEASE).
    scale = interpolate(
      t,
      [c.t - ANTICIPATE, c.t, c.t + HOLD, c.t + HOLD + RELEASE],
      [1, ZOOM_SCALE, ZOOM_SCALE, 1],
      { easing, extrapolateLeft: "clamp", extrapolateRight: "clamp" }
    );

    // v1.3: anchor strictly at click coord throughout the zoom window. No
    // cursor tracking — the camera doesn't chase the user. The click itself
    // is the "point of interest" we're drawing attention to.
    const tr = computeTranslate(c.x, c.y, width, height, scale);
    tx = tr.tx;
    ty = tr.ty;
  }

  const src = videoSrc.startsWith("http") || videoSrc.startsWith("/") || videoSrc.startsWith("file:")
    ? videoSrc
    : staticFile(videoSrc);

  return (
    <AbsoluteFill style={{ backgroundColor: "black", overflow: "hidden" }}>
      <AbsoluteFill
        style={{
          transform: `translate(${-tx}px, ${-ty}px) scale(${scale})`,
          transformOrigin: "0 0",
        }}
      >
        <OffthreadVideo src={src} />
      </AbsoluteFill>
    </AbsoluteFill>
  );
};
