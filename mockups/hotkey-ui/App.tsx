import { useState } from "react";
import { Desktop } from "./components/desktop.tsx";
import { Picker } from "./components/picker.tsx";
import { Pill } from "./components/pill.tsx";

// Visual plan for the windowclip hotkey recorder. Four moments of the flow,
// each rendered on a simulated macOS desktop. The mock surfaces (picker panel,
// pill) use hardcoded macOS-material colors on purpose — they depict native UI,
// not runtime-themed UI.

const VIEWS = [
  {
    key: "picker",
    label: "1 · Picker",
    title: "⌥⌘R → window picker",
    notes: [
      "Centered dark-material panel, thumbnail grid (live snapshots via ScreenCaptureKit).",
      "Arrow keys + Enter, or click. Esc closes — nothing recorded, nothing left behind.",
      "Desktop dims slightly behind it so the panel reads as modal.",
    ],
  },
  {
    key: "countdown",
    label: "2 · Countdown",
    title: "Pick → pill counts down 3·2·1",
    notes: [
      "No separate countdown overlay — the pill appears at bottom-center and IS the countdown.",
      "Names the target app so you can catch a wrong pick. Esc during countdown = cancel, nothing written.",
      "Same surface then flips to recording — one continuous piece of chrome, VoiceInk-style.",
    ],
  },
  {
    key: "recording",
    label: "3 · Recording",
    title: "Recording — the pill is the only chrome",
    notes: [
      "Red dot + elapsed time, mono digits. Stop via: click Stop, Esc (hijacked only while recording), or ⌥⌘R again.",
      "Pill is excluded from capture (it's a separate window; SCK records only the target window anyway).",
      "5-minute safety cap carries over from the CLI recorder.",
    ],
  },
  {
    key: "saved",
    label: "4 · Saved",
    title: "Stop → saved confirmation, fades out",
    notes: [
      "Recorder finalizes (same clean SIGTERM path the Claude flow uses), pill flashes the filename + duration.",
      "Fades after ~4s. Click the filename to reveal in Finder. File lands at ~/Desktop/<slug>-<ts>.mp4.",
    ],
  },
] as const;

type ViewKey = (typeof VIEWS)[number]["key"];

export function App() {
  const [view, setView] = useState<ViewKey>("picker");
  const active = VIEWS.find((v) => v.key === view)!;

  return (
    <main className="min-h-full bg-background text-foreground">
      <div className="mx-auto max-w-3xl px-6 py-6">
        <header className="flex items-baseline justify-between">
          <div>
            <h1 className="text-lg font-semibold tracking-tight">windowclip · hotkey recorder</h1>
            <p className="mt-0.5 text-sm text-muted-foreground">
              Visual plan — the four moments of the flow. Native macOS surfaces, mocked.
            </p>
          </div>
          <span className="shrink-0 whitespace-nowrap font-mono text-xs text-muted-foreground">v1 · no pause · no menubar UI</span>
        </header>

        {/* view switcher */}
        <nav className="mt-5 flex gap-1.5">
          {VIEWS.map((v) => (
            <button
              key={v.key}
              onClick={() => setView(v.key)}
              className={
                "rounded-md border px-3 py-1.5 text-xs font-medium transition " +
                (v.key === view
                  ? "border-accent bg-accent/15 text-foreground"
                  : "border-border bg-card text-muted-foreground hover:text-foreground")
              }
            >
              {v.label}
            </button>
          ))}
        </nav>

        <h2 className="mt-5 text-sm font-medium">{active.title}</h2>

        {/* the simulated desktop */}
        <div className="mt-3">
          {view === "picker" && (
            <Desktop dimmed>
              <Picker selected={0} />
            </Desktop>
          )}
          {view === "countdown" && (
            <Desktop>
              <Pill state="countdown" count={3} />
            </Desktop>
          )}
          {view === "recording" && (
            <Desktop>
              <Pill state="recording" />
            </Desktop>
          )}
          {view === "saved" && (
            <Desktop>
              <Pill state="saved" />
            </Desktop>
          )}
        </div>

        {/* design notes for this moment */}
        <ul className="mt-4 space-y-1.5">
          {active.notes.map((n, i) => (
            <li key={i} className="flex gap-2 text-[13px] leading-snug text-muted-foreground">
              <span className="mt-[7px] h-1 w-1 shrink-0 rounded-full bg-accent" />
              {n}
            </li>
          ))}
        </ul>
      </div>
    </main>
  );
}
