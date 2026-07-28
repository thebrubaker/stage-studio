// AppDelegate — app lifecycle plus the debug-show harness.
//
// Every surface must be summonable deterministically, without a hotkey and
// without a real recording, so it can be screenshotted and judged:
//
//   StageStudio.app/Contents/MacOS/StageStudio --debug-show pill-recording
//
// In debug mode the app prints the CGWindowID of each surface it puts on screen,
// so `screencapture -l <id>` targets the REAL rendered window.

import AppKit

struct LaunchOptions {
    var debugShow: String?
    var debugMidline = false
    var debugFreeze = false
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: LaunchOptions
    private var pill: PillController?

    nonisolated init(options: LaunchOptions) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let surface = options.debugShow {
            runDebugSurface(surface)
        } else {
            // Phase 1: the hotkey/session machinery isn't wired yet. Fail loudly
            // rather than sitting invisible in the background pretending to work.
            FileHandle.standardError.write(Data(
                "stage-studio: no --debug-show surface given, and the hotkey session isn't wired yet.\n".utf8
            ))
            NSApp.terminate(nil)
        }
    }

    private func runDebugSurface(_ surface: String) {
        let pill = PillController(showMidline: options.debugMidline, freezeAnimation: options.debugFreeze)
        self.pill = pill
        pill.onStop = { note("stop tapped") }

        switch surface {
        case "pill-countdown":
            pill.show(.countdown(remaining: 3, appName: "Linear"))
        case "pill-recording":
            pill.show(.recording(elapsed: 42))
        case "pill-saved":
            pill.show(.saved(filename: "linear-demo.mp4", duration: 42))
        case "picker":
            FileHandle.standardError.write(Data("stage-studio: picker surface not built yet\n".utf8))
            NSApp.terminate(nil)
            return
        default:
            FileHandle.standardError.write(Data(
                "stage-studio: unknown --debug-show \(surface). Try: picker, pill-countdown, pill-recording, pill-saved\n".utf8
            ))
            exit(64)
        }

        // Window numbers only exist once the panel is on screen; let the run loop
        // turn over once so the id we print is the real one.
        DispatchQueue.main.async {
            note("window id: \(pill.windowID.map(String.init) ?? "<unavailable>")")
            note("capture region: \(pill.captureRegion ?? "<unavailable>")")
            note("showing \(surface) — Ctrl-C or `pkill -f StageStudio` to dismiss")
        }
    }
}

func note(_ message: String) {
    print("[stage-studio] \(message)")
    fflush(stdout)
}
