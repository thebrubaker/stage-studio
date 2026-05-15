import { Composition } from "remotion";
import { Clickzoom, type ClickzoomProps } from "./Clickzoom";
import { WindowCompose, type WindowComposeProps } from "./WindowCompose";
import metadata from "./input.json";

// input.json carries metadata for whichever composition we're rendering. Schema
// is permissive — fields are optional and consumed by the matching composition.
//   {
//     videoSrc: string,           // path to recorded MP4 (relative to public/)
//     width: number,              // video pixel width (source)
//     height: number,             // video pixel height (source)
//     durationSeconds: number,
//     fps: number,
//
//     // Clickzoom (v1, backlogged): zoom-on-click
//     clicks?: Array<{ t: number, x: number, y: number, button: string }>,
//     cursor?: Array<{ t: number, x: number, y: number }>,
//
//     // WindowCompose (v2): pose a window region on a styled canvas
//     bounds?: { x: number, y: number, w: number, h: number },
//     outputWidth?: number,       // composition output W (defaults 1920)
//     outputHeight?: number,      // composition output H (defaults 1080)
//   }
type FullMeta = ClickzoomProps & WindowComposeProps & {
  durationSeconds: number;
  fps: number;
  outputWidth?: number;
  outputHeight?: number;
};
const m = metadata as FullMeta;

// v2 fixed 16:9 output. 1920x1080 is the universal default. Could be made
// configurable later (e.g. 1:1 for social) but starting fixed keeps shipping fast.
const OUT_W = m.outputWidth ?? 1920;
const OUT_H = m.outputHeight ?? 1080;

export const RemotionRoot: React.FC = () => {
  return (
    <>
      <Composition
        id="Clickzoom"
        component={Clickzoom}
        durationInFrames={Math.ceil(m.durationSeconds * m.fps)}
        fps={m.fps}
        width={m.width}
        height={m.height}
        defaultProps={{
          videoSrc: m.videoSrc,
          width: m.width,
          height: m.height,
          clicks: m.clicks ?? [],
          cursor: m.cursor ?? [],
        }}
      />
      <Composition
        id="WindowCompose"
        component={WindowCompose}
        durationInFrames={Math.ceil(m.durationSeconds * m.fps)}
        fps={m.fps}
        width={OUT_W}
        height={OUT_H}
        defaultProps={{
          videoSrc: m.videoSrc,
          srcW: m.width,
          srcH: m.height,
        }}
      />
    </>
  );
};
