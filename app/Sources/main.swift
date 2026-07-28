// stage-studio hotkey recorder — LSUIElement agent app.
//
// Global hotkey → window picker → countdown → record → stop pill. The recording
// itself is delegated to the existing `cmd/recorder` binary; this app is the
// front door, not a second implementation.

import AppKit

func usage() -> Never {
    let text = """
    stage-studio hotkey recorder

    Usage:
      StageStudio [--debug-show <surface>] [--debug-midline] [--debug-freeze]

    Debug flags (summon a surface deterministically, no hotkey / no recording):
      --debug-show <surface>  picker | pill-countdown | pill-recording | pill-saved
      --debug-midline         draw the row midline over the pill (centering check)
      --debug-freeze          hold animations at their resting phase
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
