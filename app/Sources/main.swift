// stage-studio hotkey recorder — LSUIElement agent app.
//
// Global hotkey → window picker → countdown → record → stop pill. The recording
// itself is delegated to the existing `cmd/recorder` binary; this app is the
// front door, not a second implementation.

import AppKit

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

func usage() -> Never {
    let text = """
    stage-studio hotkey recorder

    Usage:
      StageStudio [--debug-show <surface>] [--debug-midline] [--debug-freeze]

    Debug flags (summon a surface deterministically, no hotkey / no recording):
      --debug-show <surface>     picker | pill-countdown | pill-recording | pill-saved
      --debug-capture <png>      screenshot the surface, then quit (self-cleaning)
      --debug-capture-delay <s>  settle time before the shot (default 1.8)
      --debug-timeout <s>        hard teardown for interactive runs (default 25)
      --debug-midline            draw the row midline over the pill (centering check)
      --debug-freeze             hold animations at their resting phase
      --debug-hover              force the saved filename's hover affordance on
      --debug-reveal             reveal the newest recording in Finder, then quit

    End-to-end (drives the real session, then quits):
      --debug-record <id|pattern>   window to record (CGWindowID or app/title text)
      --debug-record-seconds <s>    how long to record (default 5)
    """
    print(text)
    exit(0)
}

var options = LaunchOptions()
var argv = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < argv.count {
    switch argv[i] {
    case "--debug-show":
        i += 1
        guard i < argv.count else {
            FileHandle.standardError.write(Data("--debug-show needs a surface name\n".utf8))
            exit(64)
        }
        options.debugShow = argv[i]
    case "--debug-midline":
        options.debugMidline = true
    case "--debug-freeze":
        options.debugFreeze = true
    case "--debug-hover":
        options.debugHover = true
    case "--debug-reveal":
        options.debugReveal = true
    case "--debug-capture":
        i += 1
        guard i < argv.count else {
            FileHandle.standardError.write(Data("--debug-capture needs an output path\n".utf8))
            exit(64)
        }
        options.debugCapture = argv[i]
    case "--debug-capture-delay":
        i += 1
        options.debugCaptureDelay = Double(argv[safe: i] ?? "") ?? options.debugCaptureDelay
    case "--debug-timeout":
        i += 1
        options.debugTimeout = Double(argv[safe: i] ?? "") ?? options.debugTimeout
    case "--debug-record":
        i += 1
        guard i < argv.count else {
            FileHandle.standardError.write(Data("--debug-record needs a window id or pattern\n".utf8))
            exit(64)
        }
        options.debugRecord = argv[i]
    case "--debug-record-seconds":
        i += 1
        options.debugRecordSeconds = Double(argv[safe: i] ?? "") ?? options.debugRecordSeconds
    case "-h", "--help":
        usage()
    default:
        FileHandle.standardError.write(Data("unknown arg: \(argv[i])\n".utf8))
        exit(64)
    }
    i += 1
}

let app = NSApplication.shared
// Agent app: no Dock icon, no menu bar. Belt-and-braces with LSUIElement in the
// Info.plist so running the raw binary behaves the same as launching the bundle.
app.setActivationPolicy(.accessory)
let delegate = AppDelegate(options: options)
app.delegate = delegate
app.run()
