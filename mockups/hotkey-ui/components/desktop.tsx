import type { ReactNode } from "react";

/**
 * Simulated macOS desktop — a 16:10 frame with the windowclip indigo-ish
 * gradient wallpaper. Everything inside is mock "native" UI, so colors in
 * here are deliberately hardcoded (fidelity to macOS materials, not the
 * runtime theme).
 */
export function Desktop({ children, dimmed = false }: { children: ReactNode; dimmed?: boolean }) {
  return (
    <div
      className="relative mx-auto overflow-hidden rounded-xl border border-border shadow-2xl"
      style={{ aspectRatio: "16 / 10", height: "52vh", maxWidth: "100%" }}
    >
      {/* wallpaper */}
      <div
        className="absolute inset-0"
        style={{
          background:
            "radial-gradient(120% 90% at 20% 10%, #3b3f7a 0%, #23264f 40%, #14162e 75%, #0b0c1a 100%)",
        }}
      />
      {/* fake background windows to give depth */}
      <div className="absolute left-[6%] top-[12%] h-[62%] w-[52%] rounded-lg bg-[#1c1d22]/80 shadow-xl ring-1 ring-white/5">
        <div className="flex h-6 items-center gap-1.5 rounded-t-lg bg-[#2a2b31] px-2.5">
          <span className="h-2 w-2 rounded-full bg-[#ff5f57]" />
          <span className="h-2 w-2 rounded-full bg-[#febc2e]" />
          <span className="h-2 w-2 rounded-full bg-[#28c840]" />
        </div>
        <div className="space-y-2 p-4 opacity-30">
          <div className="h-2 w-3/5 rounded bg-white/40" />
          <div className="h-2 w-4/5 rounded bg-white/25" />
          <div className="h-2 w-2/5 rounded bg-white/25" />
          <div className="h-2 w-3/4 rounded bg-white/15" />
        </div>
      </div>
      <div className="absolute right-[8%] top-[22%] h-[55%] w-[38%] rounded-lg bg-[#191a1f]/80 shadow-xl ring-1 ring-white/5">
        <div className="flex h-6 items-center gap-1.5 rounded-t-lg bg-[#26272d] px-2.5">
          <span className="h-2 w-2 rounded-full bg-white/20" />
          <span className="h-2 w-2 rounded-full bg-white/20" />
          <span className="h-2 w-2 rounded-full bg-white/20" />
        </div>
      </div>
      {/* dim layer when a modal surface is up */}
      {dimmed && <div className="absolute inset-0 bg-black/35 backdrop-blur-[1px]" />}
      {children}
    </div>
  );
}
