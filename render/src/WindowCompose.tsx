import { AbsoluteFill, OffthreadVideo, useVideoConfig, staticFile } from "remotion";

export type WindowComposeProps = {
  videoSrc: string;
  /** Source video pixel dimensions. Source is HEVC-with-alpha captured by SCK
   *  via cmd/recorder, so the video carries the window's actual rounded-rect
   *  alpha mask. Remotion's `transparent` prop preserves alpha through frame
   *  extraction; CSS composes naturally, gradient showing through corners. */
  srcW: number;
  srcH: number;
};

// macOS-y gradient — deep indigo to near-black, like Sequoia wallpaper. The
// drop-shadow filter follows the video's actual rendered shape (which comes
// from the alpha channel), so the shadow hugs the rounded window corners.
const BG_GRADIENT = "linear-gradient(135deg, #2a1f5c 0%, #1a1240 45%, #0f0a26 100%)";
const SHADOW_FILTER =
  "drop-shadow(0 40px 60px rgba(0,0,0,0.55)) drop-shadow(0 12px 24px rgba(0,0,0,0.35))";
const PADDING_RATIO_X = 0.08;
const PADDING_RATIO_Y = 0.08;

export const WindowCompose: React.FC<WindowComposeProps> = ({ videoSrc, srcW, srcH }) => {
  const { width: outW, height: outH } = useVideoConfig();

  const padX = outW * PADDING_RATIO_X;
  const padY = outH * PADDING_RATIO_Y;
  const innerW = outW - 2 * padX;
  const innerH = outH - 2 * padY;

  const srcAspect = srcW / srcH;
  const innerAspect = innerW / innerH;

  let dispW: number;
  let dispH: number;
  if (srcAspect > innerAspect) {
    dispW = innerW;
    dispH = innerW / srcAspect;
  } else {
    dispH = innerH;
    dispW = innerH * srcAspect;
  }

  const src = videoSrc.startsWith("http") || videoSrc.startsWith("/") || videoSrc.startsWith("file:")
    ? videoSrc
    : staticFile(videoSrc);

  return (
    <AbsoluteFill style={{ background: BG_GRADIENT }}>
      <div style={{
        position: "absolute",
        left: (outW - dispW) / 2,
        top: (outH - dispH) / 2,
        width: dispW,
        height: dispH,
        // drop-shadow follows the alpha-derived video shape — hugs the rounded
        // corners that the source video already encodes via its alpha channel.
        filter: SHADOW_FILTER,
      }}>
        <OffthreadVideo
          src={src}
          transparent
          style={{
            width: "100%",
            height: "100%",
            objectFit: "fill",
          }}
        />
      </div>
    </AbsoluteFill>
  );
};
