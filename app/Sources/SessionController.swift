// SessionController — the flow itself.
//
//   idle ──⌥⌘R──▶ picking ──pick──▶ countdown 3·2·1 ──▶ recording ──stop──▶ saved ──▶ idle
//                    │                    │                  │
//                   esc                  esc               esc / ⌥⌘R / Stop
//                    ▼                    ▼                  ▼
//                   idle              idle (nothing        finalize, then saved
//                                      written)
//
// Esc is hijacked only for the span of the arrows above that have a pill on
// screen — registered when the countdown starts, unregistered when the session
// ends, in every exit path including failure.

import AppKit
import Foundation

@MainActor
final class SessionController {
    enum Phase {
        case idle
        case picking
        case countdown
        case recording
        case saved
    }

    private(set) var phase: Phase = .idle {
        didSet {
            guard phase != oldValue else { return }
            onPhaseChange?(phase)
        }
    }

    /// Observation hook. Used by the end-to-end debug harness to drive the REAL
    /// state machine rather than a parallel test-only copy of it.
    var onPhaseChange: ((Phase) -> Void)?

    private let picker = PickerController()
    private let pill: PillController
    private let recorder = Recorder()

    private var target: CapturableWindow?
    private var countdownRemaining = 0
    private var timer: Timer?
    private var savedDismissWork: DispatchWorkItem?

    /// Mockup's 3·2·1.
    private let countdownSeconds = 3
    /// How long the "Saved ✓" flash stays before fading.
    private let savedLinger: TimeInterval = 4

    init(pill: PillController) {
        self.pill = pill
        self.pill.onStop = { [weak self] in self?.stop() }
        picker.onPick = { [weak self] window in self?.beginCountdown(for: window) }
        picker.onCancel = { [weak self] in self?.phase = .idle }
    }

    // MARK: - Entry points

    /// ⌥⌘R. One key for the whole flow: summon, or stop what's running.
    func toggle() {
        switch phase {
        case .idle:
            showPicker()
        case .picking:
            picker.close(cancelled: true)
            phase = .idle
        case .countdown:
            cancelCountdown()
        case .recording:
            stop()
        case .saved:
            // Don't make the user wait out the confirmation to start the next take.
            dismissSaved()
            showPicker()
        }
    }

    /// Esc, while a pill is up.
    func escape() {
        switch phase {
        case .countdown: cancelCountdown()
        case .recording: stop()
        default: break
        }
    }

    /// Enter the flow at the moment a window has been chosen — same path the
    /// picker takes, minus the picking.
    func start(window: CapturableWindow) {
        guard phase == .idle else { return }
        beginCountdown(for: window)
    }

    /// Stop from outside (debug harness / status menu).
    func requestStop() { stop() }

    var outputURL: URL? { recorder.outputURL }

    // MARK: - Picking

    private func showPicker() {
        phase = .picking
        picker.show()
    }

    // MARK: - Countdown

    private func beginCountdown(for window: CapturableWindow) {
        target = window
        phase = .countdown
        countdownRemaining = countdownSeconds

        // Esc becomes ours for exactly as long as the pill is up.
        HotkeyManager.shared.register(.escape) { [weak self] in self?.escape() }

        pill.show(.countdown(remaining: countdownRemaining, appName: window.app))
        startTimer(interval: 1) { [weak self] in self?.tickCountdown() }
    }

    private func tickCountdown() {
        countdownRemaining -= 1
        if countdownRemaining > 0 {
            pill.update(.countdown(remaining: countdownRemaining, appName: target?.app ?? ""))
        } else {
            stopTimer()
            beginRecording()
        }
    }

    private func cancelCountdown() {
        stopTimer()
        // Nothing was ever spawned — a cancelled countdown writes no file at all.
        endSession()
    }

    // MARK: - Recording

    private func beginRecording() {
        guard let target else { return endSession() }
        let output = Recorder.defaultOutputURL()

        recorder.onExit = { [weak self] status in self?.recorderExited(status: status) }
        do {
            try recorder.start(windowID: target.id, output: output)
        } catch {
            note("failed to start recorder: \(error.localizedDescription)")
            NSSound.beep()
            return endSession()
        }

        phase = .recording
        pill.update(.recording(elapsed: 0))
        startTimer(interval: 0.5) { [weak self] in self?.tickElapsed() }
    }

    private func tickElapsed() {
        guard phase == .recording else { return }
        pill.update(.recording(elapsed: recorder.elapsed))
    }

    private func stop() {
        guard phase == .recording else { return }
        stopTimer()
        // Hold the recording pill until the recorder has actually finalized —
        // flashing "Saved" before the file is written would be a lie.
        recorder.stop()
    }

    private func recorderExited(status: Int32) {
        stopTimer()
        let output = recorder.outputURL
        let duration = recorder.elapsed

        guard status == 0, let output, FileManager.default.fileExists(atPath: output.path) else {
            note("recorder exited \(status) without a usable file")
            NSSound.beep()
            return endSession()
        }

        phase = .saved
        pill.update(.saved(filename: output.lastPathComponent, duration: duration))
        HotkeyManager.shared.unregister(.escape)

        let work = DispatchWorkItem { [weak self] in self?.dismissSaved() }
        savedDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + savedLinger, execute: work)
    }

    private func dismissSaved() {
        savedDismissWork?.cancel()
        savedDismissWork = nil
        pill.fadeOut { [weak self] in
            guard let self, phase == .saved || phase == .idle else { return }
            phase = .idle
        }
        phase = .idle
    }

    // MARK: - Teardown

    /// Every exit path funnels here, so Esc can never stay hijacked past the pill.
    private func endSession() {
        stopTimer()
        recorder.cancel()
        HotkeyManager.shared.unregister(.escape)
        pill.hide()
        target = nil
        phase = .idle
    }

    /// Called on app termination — never leave a recorder orphaned.
    func shutdown() {
        stopTimer()
        HotkeyManager.shared.unregister(.escape)
        if recorder.isRunning { recorder.cancel() }
    }

    // MARK: - Timer

    private func startTimer(interval: TimeInterval, _ tick: @escaping () -> Void) {
        stopTimer()
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        // .common so the countdown keeps ticking while a menu or resize loop is up.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
