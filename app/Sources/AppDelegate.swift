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
    /// Screenshot the surface to this path and quit. Debug surfaces appear on the
    /// user's REAL screen — a floating panel parked there while someone goes off
    /// to analyze the shot is in their way, so capture is self-terminating by
    /// construction rather than by remembering to clean up.
    var debugCapture: String?
    /// Time to let the surface settle (thumbnails stream in async) before capture.
    var debugCaptureDelay: Double = 1.8
    /// Backstop for interactive debug runs: a surface can never outlive this.
    var debugTimeout: Double = 25
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: LaunchOptions
    private var pill: PillController?
    private var picker: PickerController?

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
        if surface == "picker" {
            let picker = PickerController()
            self.picker = picker
            picker.onPick = { window in
                note("picked: \(window.app) — \(window.title) [\(window.id)]")
                NSApp.terminate(nil)
            }
            picker.onCancel = {
                note("picker cancelled")
                NSApp.terminate(nil)
            }
            picker.show()
            DispatchQueue.main.async { [self] in
                note("window id: \(picker.windowID.map(String.init) ?? "<unavailable>")")
                note("showing picker — arrows + return to pick, esc to close")
                armCapture { picker.captureRegion }
            }
            return
        }

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
        default:
            FileHandle.standardError.write(Data(
                "stage-studio: unknown --debug-show \(surface). Try: picker, pill-countdown, pill-recording, pill-saved\n".utf8
            ))
            exit(64)
        }

        // Window numbers only exist once the panel is on screen; let the run loop
        // turn over once so the id we print is the real one.
        DispatchQueue.main.async { [self] in
            note("window id: \(pill.windowID.map(String.init) ?? "<unavailable>")")
            note("showing \(surface) — Ctrl-C or `pkill -f StageStudio` to dismiss")
            armCapture { pill.captureRegion }
        }
    }

    /// Self-terminating verification: screenshot the surface, then quit. Also
    /// arms a hard timeout for interactive runs, so no debug surface can outlive
    /// its welcome on someone's real desktop.
    private func armCapture(_ region: @escaping () -> String?) {
        if let path = options.debugCapture {
            DispatchQueue.main.asyncAfter(deadline: .now() + options.debugCaptureDelay) {
                guard let region = region() else {
                    FileHandle.standardError.write(Data("stage-studio: no capture region\n".utf8))
                    NSApp.terminate(nil)
                    return
                }
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                task.arguments = ["-R\(region)", "-o", "-x", path]
                try? task.run()
                task.waitUntilExit()
                note("captured \(path) (region \(region))")
                NSApp.terminate(nil)
            }
            return
        }
        note("capture region: \(region() ?? "<unavailable>")")
        DispatchQueue.main.asyncAfter(deadline: .now() + options.debugTimeout) {
            note("debug timeout reached — tearing the surface down")
            NSApp.terminate(nil)
        }
    }
}

func note(_ message: String) {
    print("[stage-studio] \(message)")
    fflush(stdout)
}
