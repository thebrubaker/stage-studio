// SetupController — owns the first-run setup window.
//
// Unlike the pill (chrome that must never take focus) and the picker (a modal
// moment that closes on Esc), this is a real window a user reads, leaves to visit
// System Settings, and comes back to. So it is a titled, closable, movable
// NSWindow rather than a borderless panel: it needs a close button the user can
// find without being told, and it must survive losing focus.
//
// The titlebar is transparent with `.fullSizeContentView`, so the panel material
// runs to the top edge and the traffic lights float over it — the picker's look,
// with the window affordances a window needs.

import AppKit
import SwiftUI

final class SetupWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class SetupController: NSObject, NSWindowDelegate {
    private var window: SetupWindow?
    private var hosting: NSHostingView<SetupView>?
    private var keyMonitor: Any?

    let model = SetupModel()

    /// A row's button was hit. The controller stays dumb about what each action
    /// *does* — requesting, relaunching and deep-linking are the app's business,
    /// not the window's.
    var onAction: (PermissionKind, PermissionStatus) -> Void = { _, _ in }
    /// The user dismissed the window (Done, the close button, or Esc).
    var onClose: () -> Void = {}

    var isVisible: Bool { window?.isVisible ?? false }

    /// Printed in debug runs so `screencapture -l <id>` can target the real
    /// rendered window.
    var windowID: CGWindowID? {
        guard let window, window.windowNumber > 0 else { return nil }
        return CGWindowID(window.windowNumber)
    }

    /// `x,y,w,h` in top-left screen coordinates for `screencapture -R` — the same
    /// contract the pill and picker expose, so the existing capture harness works
    /// on this surface unchanged.
    var captureRegion: String? {
        guard let window, let primary = NSScreen.screens.first else { return nil }
        let f = window.frame
        return "\(Int(f.minX)),\(Int(primary.frame.maxY - f.maxY)),\(Int(f.width)),\(Int(f.height))"
    }

    // MARK: - Lifecycle

    func show() {
        let window = window ?? makeWindow()
        layout(window)
        // An accessory app's window still has to become key for its buttons and
        // close box to work, so this activates. It is the only surface in the app
        // that deliberately takes focus.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    /// Re-render after a status changed underneath us (a grant arrived, a request
    /// was refused). Layout is redone because the rows change height with their
    /// guidance text.
    func refresh() {
        guard let window else { return }
        layout(window)
    }

    func close() {
        removeKeyMonitor()
        window?.orderOut(nil)
        // Hand focus back to whatever the user was actually using.
        NSApp.hide(nil)
    }

    // MARK: - Keyboard

    /// Esc closes, matching the picker. The window is not modal — anything else
    /// the user types belongs to the app they were in.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated {
                guard self.isVisible, event.keyCode == 53 else { return event }
                self.close()
                self.onClose()
                return nil
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    // MARK: - Window

    private func makeWindow() -> SetupWindow {
        let window = SetupWindow(
            contentRect: NSRect(x: 0, y: 0, width: Theme.setupWidth, height: 320),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Stage Studio Setup"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Otherwise AppKit rules a hairline across the window under the traffic
        // lights, which cuts the panel in two and reads as a rendering seam.
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        // The panel material is the background; a vibrant-dark appearance is what
        // makes the traffic lights and the native buttons draw for a dark surface.
        window.appearance = NSAppearance(named: .vibrantDark)
        // Nothing to minimize or zoom — the window is one fixed-size page.
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.animationBehavior = .none
        window.delegate = self

        let hostingView = NSHostingView(rootView: makeRootView())
        // NSHostingView is Auto Layout-native: left at the default, `frame` is
        // ignored and it can end up sized to nothing, which renders as a window
        // that draws only its titlebar. (Seen exactly that way.) Same treatment
        // as PillController.
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]
        // `.fullSizeContentView` puts the titlebar's height into SwiftUI's safe
        // area, so the panel material stopped BELOW the traffic lights and the top
        // 34pt of the window showed straight through to whatever was behind it.
        // (Seen in a screenshot: a terminal's toolbar visible inside our window.)
        // The window owns its own top inset via Theme.setupTitlebarInset instead.
        hostingView.safeAreaRegions = []
        window.contentView = hostingView

        self.hosting = hostingView
        self.window = window
        return window
    }

    private func makeRootView() -> SetupView {
        SetupView(
            model: model,
            onAction: { [weak self] kind, status in self?.onAction(kind, status) },
            onDone: { [weak self] in
                self?.close()
                self?.onClose()
            }
        )
    }

    /// Size the window to its content, then place it.
    ///
    /// The order is load-bearing: `fittingSize` only means anything after a layout
    /// pass, and both branches below need the FINAL height. Measured on a 2560×1440
    /// display, the resulting origin is an exact function of the final content
    /// height across every row state (240pt→y 299, 266→293, 343→273 — one curve), so
    /// `center()` is genuinely seeing the settled frame rather than racing it.
    ///
    /// On a *re*-layout the TOP-LEFT is pinned instead of centering again. Rows
    /// change height when their guidance text does — a `denied` row wraps to two
    /// lines, the ready state grows a whole footer — and an NSWindow keeps its
    /// bottom-left origin, so it grows *upward*: the header would jump out from
    /// under the reader's eye each time a permission resolved. Recentering instead
    /// would move the window under their cursor, which is worse.
    private func layout(_ window: SetupWindow) {
        guard let hosting else { return }
        let wasVisible = window.isVisible
        let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        hosting.rootView = makeRootView()
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        window.setContentSize(size)
        hosting.frame = window.contentView?.bounds ?? NSRect(origin: .zero, size: size)
        if wasVisible {
            window.setFrameTopLeftPoint(topLeft)
        } else {
            window.center()
        }
        note("setup window: content \(Int(size.width))×\(Int(size.height)), frame \(window.frame)")
    }

    // MARK: - NSWindowDelegate

    /// Covers the close button, which doesn't route through `close()`.
    func windowWillClose(_ notification: Notification) {
        removeKeyMonitor()
        onClose()
    }
}
