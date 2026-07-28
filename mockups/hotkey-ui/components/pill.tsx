/**
 * The VoiceInk-style pill — bottom-center, the ONLY chrome during a session.
 * Three states, one surface:
 *   countdown → "3" ticking down, before capture starts (cancellable)
 *   recording → red dot + elapsed + stop; esc / ⌥⌘R / click all stop
 *   saved     → confirmation flash, then fades out
 */
export type PillState = "countdown" | "recording" | "saved";

export function Pill({ state, count = 3 }: { state: PillState; count?: number }) {
  return (
    <div className="absolute inset-x-0 bottom-[4%] flex justify-center">
      <div
        className="flex items-center gap-3 rounded-full px-4 py-2 shadow-2xl ring-1 ring-white/10"
        style={{ background: "rgba(12,12,14,0.94)", backdropFilter: "blur(20px)" }}
      >
        {state === "countdown" && (
          <>
            <span className="relative flex h-5 w-5 items-center justify-center">
              <span className="absolute inset-0 rounded-full border border-white/25" />
              <span className="text-[11px] font-semibold text-white/90">{count}</span>
            </span>
            <span className="translate-y-[1px] text-[12px] font-medium text-white/80">Recording Linear…</span>
            <span className="flex items-center gap-1.5 text-[10px] text-white/35">
              <Kbd>esc</Kbd> <span className="translate-y-[0.5px]">cancel</span>
            </span>
          </>
        )}
        {state === "recording" && (
          <>
            <span className="relative flex h-2.5 w-2.5">
              <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-red-500 opacity-60" />
              <span className="relative inline-flex h-2.5 w-2.5 rounded-full bg-red-500" />
            </span>
            <span className="font-mono text-[12px] tabular-nums text-white/90">0:42</span>
            <span className="h-3.5 w-px bg-white/15" />
            <button className="flex items-center gap-1.5 rounded-full px-1 text-[12px] font-medium text-white/85 hover:text-white">
              <span className="inline-block h-2.5 w-2.5 rounded-[2px] bg-white/85" />
              <span className="translate-y-[1px]">Stop</span>
            </button>
            <span className="flex items-center gap-1.5 text-[10px] text-white/35">
              <span className="translate-y-[0.5px]">or</span> <Kbd>esc</Kbd>
            </span>
          </>
        )}
        {state === "saved" && (
          <>
            <span className="flex h-4 w-4 items-center justify-center rounded-full bg-emerald-500/90 text-[10px] font-bold text-black">
              ✓
            </span>
            <span className="text-[12px] font-medium text-white/85">
              Saved <span className="font-mono text-white/50">linear-demo.mp4</span>
              <span className="text-white/40"> · 0:42</span>
            </span>
          </>
        )}
      </div>
    </div>
  );
}

function Kbd({ children }: { children: React.ReactNode }) {
  return (
    <kbd className="rounded border border-white/15 bg-white/[0.06] px-1 py-px font-mono text-[9px] text-white/50">
      {children}
    </kbd>
  );
}
