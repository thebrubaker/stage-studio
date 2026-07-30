import { MOCK_WINDOWS } from "../data.ts";

/**
 * The window picker — summoned by ⌥⌘R. A centered floating panel in the
 * macOS dark-material style: thumbnail grid, app icon + title, keyboard
 * navigable. Selected item carries the focus ring.
 */
export function Picker({ selected = 0 }: { selected?: number }) {
  return (
    <div className="absolute inset-0 flex items-center justify-center p-[6%]">
      <div
        className="w-[78%] max-w-[560px] rounded-2xl border border-white/10 shadow-2xl"
        style={{ background: "rgba(28,28,32,0.92)", backdropFilter: "blur(24px)" }}
      >
        <div className="flex items-center justify-between px-4 pb-1 pt-3">
          <span className="text-[11px] font-medium uppercase tracking-widest text-white/40">
            Record a window
          </span>
          <span className="font-mono text-[10px] text-white/25">windowclip</span>
        </div>
        <div className="grid grid-cols-3 gap-2 p-3">
          {MOCK_WINDOWS.map((w, i) => (
            <div
              key={w.windowId}
              className={
                "group cursor-pointer rounded-lg p-1.5 transition " +
                (i === selected ? "bg-white/10 ring-2 ring-[#4f8ef7]" : "hover:bg-white/5")
              }
            >
              {/* thumbnail */}
              <div
                className="relative aspect-[16/10] overflow-hidden rounded-md ring-1 ring-white/10"
                style={{ background: `linear-gradient(135deg, ${w.from}, ${w.to})` }}
              >
                <div className="absolute inset-x-2 top-2 space-y-1 opacity-40">
                  <div className="h-1 w-2/3 rounded bg-white/60" />
                  <div className="h-1 w-1/2 rounded bg-white/35" />
                </div>
              </div>
              {/* label */}
              <div className="mt-1.5 flex items-center gap-2 px-0.5">
                <span
                  className="flex h-6 w-6 shrink-0 items-center justify-center rounded-[6px] text-[12px] font-bold leading-none text-white/95 ring-1 ring-inset ring-white/20"
                  style={{ background: w.from }}
                >
                  {w.glyph}
                </span>
                <div className="min-w-0">
                  <div className="truncate text-[11px] font-medium leading-tight text-white/85">{w.app}</div>
                  <div className="truncate text-[9.5px] leading-tight text-white/35">{w.title}</div>
                </div>
              </div>
            </div>
          ))}
        </div>
        <div className="flex items-center justify-between border-t border-white/[0.07] px-4 py-2.5">
          <span className="flex items-center gap-4 text-[10px] text-white/30">
            <span className="flex items-center gap-1.5">
              <Kbd wide>← → ↑ ↓</Kbd> navigate
            </span>
            <span className="flex items-center gap-1.5">
              <Kbd>↩</Kbd> record
            </span>
          </span>
          <span className="flex items-center gap-1.5 text-[10px] text-white/30">
            <Kbd>esc</Kbd> close
          </span>
        </div>
      </div>
    </div>
  );
}

function Kbd({ children, wide }: { children: React.ReactNode; wide?: boolean }) {
  return (
    <kbd
      className={
        "rounded border border-white/15 bg-white/[0.06] px-1.5 py-0.5 font-mono text-[9px] leading-none text-white/55 " +
        (wide ? "tracking-[0.08em]" : "")
      }
    >
      {children}
    </kbd>
  );
}
