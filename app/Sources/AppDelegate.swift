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
    /// Force the saved pill's filename into its hover treatment, so the click
    /// affordance can be screenshotted without parking a pointer on the pill.
    var debugHover = false
    /// Exercise the Finder-reveal call directly, then quit.
    var debugReveal = false
    /// Dress a debug surface as an agent-initiated session (violet ring +
    /// attribution). The agent pill has its own text runs — "Claude · Recording
    /// Linear…", "Claude · 0:42" — and a text run that can't be summoned can't be
    /// measured, so the attribution states are first-class debug surfaces too.
    var debugAgent = false
    var debugLabel = "Claude"
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: LaunchOptions
    private var pill: PillController?
    private var picker: PickerController?
    private var session: SessionController?
    private var statusItem: NSStatusItem?
    private var control: ControlServer?

    nonisolated init(options: LaunchOptions) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if options.debugReveal {
            revealInFinder(Self.newestRecording())
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
        } else if let surface = options.debugShow {
            runDebugSurface(surface)
        } else if let target = options.debugRecord {
            runEndToEnd(target: target)
        } else {
            startSession()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        session?.shutdown()
        control?.stop()
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
        startControlServer(session: session)
        note("ready — ⌥⌘R to record")
    }

    /// The external control surface. Failing to open it must not take the app
    /// down — the hotkey flow is still perfectly usable without it, and a hard
    /// exit here would break the thing that already works.
    private func startControlServer(session: SessionController) {
        let server = ControlServer()
        server.handler = { [weak session] request, respond in
            guard let session else {
                return respond(["ok": false, "error": "unavailable"])
            }
            AppDelegate.handle(request, session: session, respond: respond)
        }
        do {
            try server.start()
            control = server
        } catch {
            FileHandle.standardError.write(Data(
                "stage-studio: control socket unavailable: \(error.localizedDescription)\n".utf8
            ))
        }
    }

    /// The control vocabulary. Kept static and session-parameterised so it has no
    /// hidden state of its own.
    private static func handle(
        _ request: ControlRequest,
        session: SessionController,
        respond: @escaping ([String: Any]) -> Void
    ) {
        func reply(_ result: SessionResult) {
            var payload: [String: Any] = ["ok": result.ok, "state": result.state]
            if let output = result.output { payload["output"] = output.path }
            if result.duration > 0 { payload["duration"] = result.duration }
            if result.cancelled { payload["cancelled"] = true }
            if let error = result.error { payload["error"] = error }
            respond(payload)
        }

        switch request.command {
        case "ping":
            respond(["ok": true, "state": session.describe(session.phase)])

        case "status":
            respond(session.statusPayload())

        case "start":
            guard let windowId = request.int("windowId") else {
                return respond(["ok": false, "error": "bad_request",
                                "message": "start requires windowId"])
            }
            guard let window = WindowEnumerator.list()
                .first(where: { $0.id == CGWindowID(windowId) })
            else {
                return respond(["ok": false, "error": "window_not_found",
                                "message": "no on-screen window with id \(windowId)"])
            }
            let source: SessionSource = {
                guard request.string("source") != "human" else { return .human }
                return .agent(label: request.string("label") ?? "Claude")
            }()
            let output = request.string("output").map { URL(fileURLWithPath: $0) }
            session.start(window: window, source: source, output: output) { reply($0) }

        case "stop":
            session.requestStop { reply($0) }

        case "cancel":
            session.requestCancel { reply($0) }

        // The human override, fired deterministically. `escape` is NOT another
        // way to cancel — `cancel` already exists. It calls the very function the
        // physical Esc key calls, with no waiter of its own, so what it proves is
        // that a user overriding an agent's session resolves that agent's pending
        // `start` as cancelled. A synthetic key event can't prove that (the hotkey
        // is a Carbon grab, not a keystroke anyone can inject without an
        // Accessibility grant this app deliberately doesn't have), so the same
        // entry point is exposed directly rather than approximated.
        case "escape":
            session.escape()
            respond(["ok": true, "state": session.describe(session.phase)])

        default:
            respond(["ok": false, "error": "unknown_command", "message": request.command])
        }
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

    /// The debug saved-pill points at a REAL file when one exists, so its click
    /// target is actually clickable rather than a dead path.
    private static func newestRecording() -> URL {
        let fm = FileManager.default
        let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first
        let candidates = desktop.flatMap {
            try? fm.contentsOfDirectory(
                at: $0, includingPropertiesForKeys: [.contentModificationDateKey]
            )
        } ?? []
        let newest = candidates
            .filter { $0.lastPathComponent.hasPrefix("recording-") && $0.pathExtension == "mp4" }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return da < db
            }
        return newest ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Desktop/recording-example.mp4")
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

        let pill = PillController(
            showMidline: options.debugMidline,
            freezeAnimation: options.debugFreeze,
            forceHover: options.debugHover
        )
        self.pill = pill
        pill.source = options.debugAgent ? .agent(label: options.debugLabel) : .human
        pill.onStop = { note("stop tapped") }
        // The real reveal call — not a stand-in — so clicking the filename in a
        // debug surface proves the shipping path.
        pill.onReveal = { url in revealInFinder(url) }
        pill.onHoverChanged = { note("pointer \($0 ? "entered" : "left") the pill") }

        switch surface {
        case "pill-countdown":
            pill.show(.countdown(remaining: 3, appName: "Linear"))
        case "pill-recording":
            pill.show(.recording(elapsed: 42))
        case "pill-saved":
            pill.show(.saved(url: Self.newestRecording(), duration: 42))
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
