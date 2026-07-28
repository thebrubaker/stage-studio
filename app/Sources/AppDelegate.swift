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
    /// Where the end-to-end run writes. Same `--output` the control surface takes,
    /// so a harness recording can land somewhere disposable — and so the history
    /// it feeds carries the real, arbitrary filenames a caller actually asks for
    /// rather than only the Desktop default.
    var debugRecordOutput: String?
    /// Force the saved pill's filename into its hover treatment, so the click
    /// affordance can be screenshotted without parking a pointer on the pill.
    var debugHover = false
    /// Exercise the Finder-reveal call directly, then quit.
    var debugReveal = false
    /// Fire the status menu's Nth "Recent Recordings" item — the real NSMenuItem,
    /// its real target/action — then quit. A menu item is only as good as what
    /// happens when it is clicked, and clicking one for real needs an
    /// Accessibility grant this app deliberately doesn't have.
    var debugRevealRecent: Int?
    /// Dress a debug surface as an agent-initiated session (violet ring +
    /// attribution). The agent pill has its own text runs — "Claude · Recording
    /// Linear…", "Claude · 0:42" — and a text run that can't be summoned can't be
    /// measured, so the attribution states are first-class debug surfaces too.
    var debugAgent = false
    var debugLabel = "Claude"
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
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
        } else if let index = options.debugRevealRecent {
            runDebugRevealRecent(index)
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

    /// Not the interface — the app is the pill and the picker. This exists so an
    /// agent app with no Dock icon has a visible way to quit, and (DIG-795) so the
    /// last five recordings stay findable after their pill has faded.
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "record.circle",
            accessibilityDescription: "Stage Studio"
        )
        let menu = NSMenu()
        // The recents section decides its own enablement (a file that has moved
        // is shown greyed rather than firing into nothing), so AppKit's automatic
        // validation has to stay out of it.
        menu.autoenablesItems = false
        menu.delegate = self
        rebuildMenu(menu)
        item.menu = menu
        statusItem = item
    }

    /// Rebuilt every time the menu is about to open, not once at launch: the
    /// history changes underneath it as recordings are made, and a file's
    /// existence is only worth checking at the moment someone can click it.
    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let record = NSMenuItem(
            title: "Record a Window…", action: #selector(recordFromMenu), keyEquivalent: "r"
        )
        record.keyEquivalentModifierMask = [.command, .option]
        record.target = self
        menu.addItem(record)

        menu.addItem(.separator())
        let header = NSMenuItem(title: "Recent Recordings", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let entries = RecentRecordings.shared.entries
        if entries.isEmpty {
            let empty = NSMenuItem(title: "Nothing yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            empty.indentationLevel = 1
            menu.addItem(empty)
        } else {
            for entry in entries { menu.addItem(recentItem(for: entry)) }
        }

        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(title: "Quit Stage Studio", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q")
        )
    }

    private func recentItem(for entry: RecentRecordings.Entry) -> NSMenuItem {
        let url = entry.url
        let exists = FileManager.default.fileExists(atPath: url.path)
        let name = RecentRecordings.displayName(for: url)
        // A recording that has been moved or thrown away stays listed but greyed
        // and labelled — silently dropping it would leave the user wondering
        // whether the app forgot, and firing a reveal at a dead path would beep
        // for no reason they can see.
        let item = NSMenuItem(
            title: exists ? name : "\(name) — missing",
            action: #selector(revealRecent(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = url
        item.isEnabled = exists
        item.indentationLevel = 1
        item.toolTip = url.path
        return item
    }

    @objc private func recordFromMenu() {
        session?.toggle()
    }

    /// The same reveal the saved pill performs — Finder, with the file selected.
    @objc private func revealRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        revealInFinder(url)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        rebuildMenu(menu)
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
        session.start(window: window, output: options.debugRecordOutput.map { URL(fileURLWithPath: $0) })

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

    /// Summon the status-item menu itself. Opening a menu runs a modal tracking
    /// loop that owns the main thread until it closes, so everything after
    /// `performClick` is scheduled off-main — including the exit, since
    /// `NSApp.terminate` would sit in a queue the tracking loop never drains.
    private func runDebugMenu() {
        installStatusItem()
        if let menu = statusItem?.menu {
            rebuildMenu(menu)
            note("menu items:")
            for item in menu.items {
                if item.isSeparatorItem { note("  ---"); continue }
                note("  \(item.isEnabled ? "•" : "×") \(item.title)")
            }
        }
        armMenuCapture()
        DispatchQueue.main.async { [self] in
            note("opening the status menu — Ctrl-C or `pkill -f StageStudio` to dismiss")
            statusItem?.button?.performClick(nil)
        }
    }

    private func armMenuCapture() {
        let path = options.debugCapture
        let delay = path == nil ? options.debugTimeout : options.debugCaptureDelay
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            if let path {
                if let id = Self.openMenuWindowID() {
                    Self.captureWindow(id, to: path)
                } else {
                    FileHandle.standardError.write(Data(
                        "stage-studio: no open menu window to capture\n".utf8
                    ))
                }
            }
            exit(0)
        }
    }

    /// The menu is drawn by this process, above the normal window levels — so
    /// "our biggest high-level window on screen" identifies it without guessing
    /// at screen coordinates that move with the status item.
    private nonisolated static func openMenuWindowID() -> CGWindowID? {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let mine = info.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == getpid() }
        let candidates = mine.filter {
            ($0[kCGWindowLayer as String] as? Int ?? 0) >= Int(CGWindowLevelForKey(.popUpMenuWindow))
        }
        func area(_ window: [String: Any]) -> Double {
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let w = bounds["Width"] as? Double, let h = bounds["Height"] as? Double
            else { return 0 }
            return w * h
        }
        return (candidates.max { area($0) < area($1) })?[kCGWindowNumber as String] as? CGWindowID
    }

    private nonisolated static func captureWindow(_ id: CGWindowID, to path: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-l\(id)", "-o", "-x", path]
        try? task.run()
        task.waitUntilExit()
        note("captured \(path) (window \(id))")
    }

    /// Click the Nth recent item the way AppKit would: a disabled item is
    /// reported and left alone, exactly as a real click on a greyed row does
    /// nothing. Everything else goes through the item's own target/action.
    private func runDebugRevealRecent(_ index: Int) {
        installStatusItem()
        guard let menu = statusItem?.menu else { exit(70) }
        rebuildMenu(menu)
        let recents = menu.items.filter { $0.representedObject is URL }
        guard let item = recents[safe: index] else {
            FileHandle.standardError.write(Data(
                "stage-studio: no recent item at index \(index) (have \(recents.count))\n".utf8
            ))
            exit(2)
        }
        note("recent[\(index)]: \"\(item.title)\" enabled=\(item.isEnabled)")
        note("path: \((item.representedObject as? URL)?.path ?? "<none>")")
        if item.isEnabled, let action = item.action, let target = item.target {
            _ = target.perform(action, with: item)
        } else {
            note("item is disabled — a click on it does nothing, by design")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { NSApp.terminate(nil) }
    }

    private func runDebugSurface(_ surface: String) {
        if surface == "menu" {
            runDebugMenu()
            return
        }

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
                "stage-studio: unknown --debug-show \(surface). Try: menu, picker, pill-countdown, pill-recording, pill-saved\n".utf8
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
