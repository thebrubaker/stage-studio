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
    /// End-to-end: drive the real session against this window (CGWindowID, or a
    /// case-insensitive substring of app+title) and quit when it's saved.
    var debugRecord: String?
    var debugRecordSeconds: Double = 5
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: LaunchOptions
    private var pill: PillController?
    private var picker: PickerController?
    private var session: SessionController?
    private var statusItem: NSStatusItem?

    nonisolated init(options: LaunchOptions) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let surface = options.debugShow {
            runDebugSurface(surface)
        } else if let target = options.debugRecord {
            runEndToEnd(target: target)
        } else {
            startSession()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        session?.shutdown()
    }

    // MARK: - Normal operation

    private func startSession() {
        let pill = PillController()
        self.pill = pill
        let session = SessionController(pill: pill)
        self.session = session

        let ok = HotkeyManager.shared.register(.toggle) { [weak session] in session?.toggle() }
        if ok {
            note("registered ⌥⌘R (Esc stays yours until a pill is up)")
        } else {
            // A hotkey we couldn't claim means the app silently does nothing —
            // say so rather than sitting there looking alive.
            FileHandle.standardError.write(Data(
                "stage-studio: could not register ⌥⌘R — another app is probably holding it.\n".utf8
            ))
        }

        installStatusItem()
        note("ready — ⌥⌘R to record")
    }

    /// Not the interface — the app is the pill and the picker. This exists only
    /// so an agent app with no Dock icon has a visible way to quit.
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "record.circle",
            accessibilityDescription: "Stage Studio"
        )
        let menu = NSMenu()
        let record = NSMenuItem(
            title: "Record a Window…", action: #selector(recordFromMenu), keyEquivalent: "r"
        )
        record.keyEquivalentModifierMask = [.command, .option]
        record.target = self
        menu.addItem(record)
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(title: "Quit Stage Studio", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q")
        )
        item.menu = menu
        statusItem = item
    }

    @objc private func recordFromMenu() {
        session?.toggle()
    }

    // MARK: - End-to-end harness

    /// Drives the REAL SessionController (countdown → recorder spawn → SIGTERM
    /// finalize → saved pill) against a named window, then quits. Deliberately
    /// not a parallel test-only path: if this passes, the thing that ran is the
    /// thing the hotkey runs.
    private func runEndToEnd(target: String) {
        let windows = WindowEnumerator.list()
        let match: CapturableWindow? = {
            if let id = UInt32(target) {
                return windows.first { $0.id == id }
            }
            let needle = target.lowercased()
            return windows.first { "\($0.app) \($0.title)".lowercased().contains(needle) }
        }()

        guard let window = match else {
            FileHandle.standardError.write(Data(
                "stage-studio: no window matched \"\(target)\" among \(windows.count) on screen\n".utf8
            ))
            exit(2)
        }

        let pill = PillController()
        self.pill = pill
        let session = SessionController(pill: pill)
        self.session = session

        note("end-to-end: \(window.app) — \(window.title) [\(window.id)]")
        session.onPhaseChange = { [weak self] phase in
            guard let self else { return }
            note("phase → \(phase)")
            switch phase {
            case .recording:
                let after = self.options.debugRecordSeconds
                DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                    note("stopping after \(after)s")
                    session.requestStop()
                }
            case .saved:
                note("output: \(session.outputURL?.path ?? "<none>")")
                self.captureAfterRedraw(options.debugCapture, region: { pill.captureRegion }) {
                    NSApp.terminate(nil)
                }
            default:
                break
            }
        }
        session.start(window: window)

        // Backstop: never leave a recorder running because a phase never arrived.
        DispatchQueue.main.asyncAfter(deadline: .now() + options.debugRecordSeconds + 30) {
            FileHandle.standardError.write(Data("stage-studio: end-to-end timed out\n".utf8))
            NSApp.terminate(nil)
        }
    }

    /// Screenshotting a surface you just mutated in the SAME run-loop turn races
    /// the redraw — `screencapture` runs synchronously and the window never gets
    /// to draw, so the shot shows the PREVIOUS state. (Caught exactly that way:
    /// a "saved" capture that came back showing the recording pill.) Always let
    /// the run loop turn over first.
    private func captureAfterRedraw(
        _ path: String?,
        region: @escaping () -> String?,
        then finish: @escaping () -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if let path, let region = region() {
                self.captureRegion(region, to: path)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: finish)
        }
    }

    private func captureRegion(_ region: String, to path: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-R\(region)", "-o", "-x", path]
        try? task.run()
        task.waitUntilExit()
        note("captured \(path) (region \(region))")
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
                self.captureRegion(region, to: path)
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
