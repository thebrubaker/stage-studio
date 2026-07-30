// SetupView — the first-run permissions gate.
//
// Windowclip is LSUIElement: it has no window at all in normal operation. This
// is the ONE exception, and it exists because a user without Screen Recording or
// Microphone grants gets silent degradation with nothing to read. It appears only
// when something is missing (or on demand from the status menu), states what is
// missing, and offers the one correct action for that state.
//
// Design vocabulary is the picker's: a real NSVisualEffectView under
// Theme.pickerTint, white-on-dark at the picker's opacities, the shared KbdChip
// for keystrokes. Nothing new invented here.

import AppKit
import SwiftUI

// MARK: - State model

/// What macOS will let us do about one permission, right now.
///
/// These four are not decorative variants of "off" — each one has a *different
/// correct action*, and picking the wrong one is the failure this window exists
/// to prevent:
///
///   needed        we can still raise the system prompt → ask
///   granted       nothing to do
///   denied        macOS will never prompt again for this app → send them to the
///                 exact Settings pane instead of a button that does nothing
///   needsRelaunch the grant exists but not for THIS process (Screen Recording
///                 only) → relaunch for them rather than leaving them to infer
///                 "quit and reopen"
enum PermissionStatus: String, Equatable, CaseIterable {
    case needed
    case granted
    case denied
    case needsRelaunch

    /// Debug-harness spelling: `--debug-screen relaunch`.
    static func parse(_ raw: String) -> PermissionStatus? {
        switch raw.lowercased() {
        case "needed", "need": return .needed
        case "granted", "grant", "ok": return .granted
        case "denied", "deny": return .denied
        case "relaunch", "needsrelaunch", "needs-relaunch": return .needsRelaunch
        default: return nil
        }
    }
}

enum PermissionKind: String, CaseIterable {
    case screenRecording
    case microphone

    var title: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .microphone: return "Microphone"
        }
    }

    /// SF Symbol for the row's icon tile.
    var symbol: String {
        switch self {
        case .screenRecording: return "display"
        case .microphone: return "mic"
        }
    }

    /// Why this app is asking. Concrete about what it buys the user, because
    /// "grant screen recording" with no reason is what makes people say no.
    /// One line, and it must FIT on one line next to the action button — a reason
    /// that wraps mid-phrase reads as a layout accident rather than a sentence.
    var reason: String {
        switch self {
        case .screenRecording: return "Capture the window you record."
        case .microphone: return "Add your voice to the recording."
        }
    }

    /// A `denied` row can't be re-prompted, so it has to say what to do when they
    /// get there — and Screen Recording additionally needs the relaunch, which
    /// Microphone doesn't.
    ///
    /// It no longer says "System Settings": the button beside it now names the pane,
    /// so repeating it here was redundant *and* expensive — the two strings competed
    /// for one row's width and the button lost, truncating to "Screen Recording
    /// Setti…". Destination belongs on the control; this line is the instruction for
    /// once you're in it.
    var deniedGuidance: String {
        switch self {
        case .screenRecording: return "Turned off. Switch it back on, then relaunch."
        case .microphone: return "Turned off. Switch it back on."
        }
    }

    /// A row whose grant exists but hasn't reached this process.
    ///
    /// Deliberately NOT an imperative. "Restart Windowclip to start using it"
    /// instructed the user to restart, and then the button hierarchy demoted the
    /// Restart button to secondary — so reading top-down you hit an order followed
    /// by a greyed-out control, which reads as the app contradicting itself. This
    /// states the fact and defers the action, which is what the demotion means.
    var relaunchGuidance: String { "Allowed — restart when you're done here." }

    /// Names the pane, because the destination is the whole information here. See
    /// `actionTitle(for:)`.
    var settingsActionTitle: String {
        switch self {
        case .screenRecording: return "Screen Recording Settings"
        case .microphone: return "Microphone Settings"
        }
    }

    func guidance(for status: PermissionStatus) -> String {
        switch status {
        case .needed, .granted: return reason
        case .denied: return deniedGuidance
        case .needsRelaunch: return relaunchGuidance
        }
    }

    func actionTitle(for status: PermissionStatus) -> String? {
        switch status {
        case .granted: return nil
        // Ellipsis: this raises a macOS prompt that needs an answer. The Settings
        // buttons don't get one — they just navigate, which is not what the
        // ellipsis means.
        case .needed: return "Allow…"
        // NOT a bare "Open Settings" on both rows. When both permissions are denied
        // the two buttons sat side by side with identical labels and identical boxes,
        // leading to two *different* panes — and the one-prominent-button rule made
        // that actively misleading rather than merely ambiguous, because colour reads
        // as priority and never as destination. A user presses blue, lands in Screen
        // Recording, fixes it, relaunches, and arrives with the microphone still off
        // having had no reason to think the grey button went somewhere else. The
        // label is the only thing that can carry a destination.
        case .denied: return settingsActionTitle
        case .needsRelaunch: return "Relaunch"
        }
    }
}

@MainActor
final class SetupModel: ObservableObject {
    @Published var screenRecording: PermissionStatus = .needed
    @Published var microphone: PermissionStatus = .needed

    func status(of kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .screenRecording: return screenRecording
        case .microphone: return microphone
        }
    }

    /// Every grant in place — the terminal state, where the window stops asking
    /// for anything and teaches the hotkey instead.
    var isReady: Bool { screenRecording == .granted && microphone == .granted }

    /// Whether the window should appear at all on launch.
    var needsAttention: Bool { !isReady }
}

// MARK: - View

struct SetupView: View {
    @ObservedObject var model: SetupModel
    var onAction: (PermissionKind, PermissionStatus) -> Void = { _, _ in }
    var onDone: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            eyebrow
            header
            rows
            footer
        }
        .frame(width: Theme.setupWidth, alignment: .leading)
        // Order matters: `.background` stacks front-to-back, so the scrim sits
        // between the content and the material — the only place it can block the
        // backdrop the material is blending in. See Theme.setupScrim.
        .background(Theme.setupScrim)
        .background(VisualEffectBackground(material: .hudWindow))
        .background(Theme.pickerTint)
        .fixedSize()
    }

    /// Same eyebrow treatment as the picker's header, so the two surfaces read as
    /// the same app. Sits below the traffic lights, which float over the content.
    private var eyebrow: some View {
        HStack {
            Text(model.isReady ? "Ready" : "Setup")
                .font(.system(size: 11, weight: .medium))
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(Color.white.opacity(0.40))
            Spacer()
            Text("windowclip")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.25))
        }
        .padding(.horizontal, Theme.setupHPadding)
        .padding(.top, Theme.setupTitlebarInset)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.isReady ? "Windowclip is ready" : "Windowclip needs your permission")
                .font(.system(size: Theme.setupTitleSize, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))
            Text(
                model.isReady
                    ? "Both permissions are in place. Nothing else to set up."
                    : "macOS keeps screen and microphone access locked until you allow it."
            )
            .font(.system(size: Theme.setupBodySize))
            .foregroundStyle(Theme.textFaint)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Theme.setupHPadding)
        .padding(.top, 10)
        .padding(.bottom, 16)
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(PermissionKind.allCases.enumerated()), id: \.element) { index, kind in
                if index > 0 {
                    Rectangle().fill(Theme.pickerFooterRule).frame(height: 1)
                }
                PermissionRowView(
                    kind: kind,
                    status: model.status(of: kind),
                    isPrimary: kind == primaryKind,
                    onAction: { onAction(kind, model.status(of: kind)) }
                )
            }
        }
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, Theme.setupHPadding)
    }

    /// The one row the user should deal with next. It gets the window's single
    /// prominent button and the Return key; every other actionable row is bordered.
    ///
    /// This is a guided sequence, not decoration. Two equal blue buttons gave the
    /// eye no entry point and made Return ambiguous — and macOS wants exactly one
    /// default button per window. `nil` means nothing is left to do, and Done in the
    /// footer becomes the default instead.
    ///
    /// `needsRelaunch` sorts LAST, not by row order, because it is the step that
    /// *ends* setup rather than one of the things setup is for. Ranking it by
    /// position put the loud button on a row already reading "Allowed." while the
    /// still-ungranted microphone sat quiet below it — and worse, the blue button
    /// held the same screen position and silently relabelled `Allow…` → `Relaunch`,
    /// so a user pressing Return twice out of momentum would restart the app instead
    /// of granting their microphone. (Caught by an adversarial read of the rendered
    /// states; see 02-screen-relaunch.) Grant everything first, then relaunch once.
    private var primaryKind: PermissionKind? {
        let blocking = PermissionKind.allCases.first {
            let status = model.status(of: $0)
            return status == .needed || status == .denied
        }
        return blocking ?? PermissionKind.allCases.first { model.status(of: $0) == .needsRelaunch }
    }

    /// Nothing to say in a state where both rows are still asking — an empty
    /// footer's padding reads as a window that failed to draw something.
    private var hasFooter: Bool { model.isReady || showsCaptureForecast }

    @ViewBuilder private var footer: some View {
        if hasFooter {
            VStack(alignment: .leading, spacing: 10) {
                if model.isReady { hotkeyLine }
                if showsCaptureForecast { forecastLine }
                if model.isReady {
                    HStack {
                        Spacer()
                        Button("Done", action: onDone)
                            .keyboardShortcut(.defaultAction)
                            .controlSize(.regular)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, Theme.setupHPadding)
            .padding(.top, 14)
            // Deeper than the 20pt side inset on purpose. A button's layout box
            // is larger than its drawn pill and a text line's box is taller than
            // its ink, so an equal 20 measured ~10–12pt of visible gap at the
            // bottom edge — tighter than the sides, which reads as truncated.
            .padding(.bottom, Theme.setupBottomPadding)
        } else {
            Color.clear.frame(height: Theme.setupBottomPadding)
        }
    }

    /// Art has no way to discover ⌥⌘R. This is where he learns it — rendered with
    /// the same KbdChip the pill and picker use, not a second keystroke language.
    private var hotkeyLine: some View {
        HStack(spacing: 6) {
            Text("Press")
                .font(.system(size: Theme.setupBodySize))
                .foregroundStyle(Color.white.opacity(0.62))
                .opticallyCentered(
                    NSFont.systemFont(ofSize: Theme.setupBodySize), rowHeight: Theme.kbdChipHeight
                )
            KbdGlyphs(symbols: ["option"], rowHeight: Theme.kbdChipHeight)
            KbdGlyphs(symbols: ["command"], rowHeight: Theme.kbdChipHeight)
            KbdKey(text: "R", rowHeight: Theme.kbdChipHeight)
            Text("anywhere to record a window.")
                .font(.system(size: Theme.setupBodySize))
                .foregroundStyle(Color.white.opacity(0.62))
                .opticallyCentered(
                    NSFont.systemFont(ofSize: Theme.setupBodySize), rowHeight: Theme.kbdChipHeight
                )
        }
    }

    /// macOS raises its OWN capture-consent dialog when a recording starts, even
    /// with Screen Recording already granted. It surprised Joel, who had granted
    /// everything — unannounced it reads as the app being broken. It can't be
    /// pre-empted, so it gets predicted.
    ///
    /// Deliberately makes NO claim about how often. The line used to promise "allow
    /// it and it won't ask again", and Sequoia-era macOS re-asks on a cadence Apple
    /// hasn't published — so the reassurance would eventually become evidence the
    /// app lied, at exactly the moment the user needed to trust it. "May ask" is
    /// true whatever Apple does next.
    private var forecastLine: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.42))
            Text("When a recording starts, macOS may ask you to confirm. That's macOS being careful with screen access — allow it and the recording begins.")
                .font(.system(size: Theme.setupBodySize))
                .foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Only meaningful once Screen Recording is actually granted — before that the
    /// user has a more immediate prompt to deal with, and forecasting a *second*
    /// dialog would just be noise.
    private var showsCaptureForecast: Bool {
        model.screenRecording == .granted
    }
}

// MARK: - Row

private struct PermissionRowView: View {
    let kind: PermissionKind
    let status: PermissionStatus
    /// This is the row to deal with next — see `SetupView.primaryKind`.
    let isPrimary: Bool
    let onAction: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.88))
                Text(kind.guidance(for: status))
                    .font(.system(size: 10.5))
                    .foregroundStyle(guidanceColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            action
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }

    private var icon: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.white.opacity(0.07))
            .frame(width: Theme.setupIconTile, height: Theme.setupIconTile)
            .overlay(
                Image(systemName: kind.symbol)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.75))
            )
    }

    /// The action area IS the state: a check when there's nothing to do, and
    /// otherwise exactly one button whose label says what will happen.
    @ViewBuilder private var action: some View {
        switch status {
        case .granted:
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Theme.savedGreen)
                Text("Allowed")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textFaint)
            }
        default:
            // Exactly one prominent button per window, on the row the user should
            // handle first. The others are still actionable — just not the answer
            // to "what do I do now?", and not what Return should press.
            if let title = kind.actionTitle(for: status) {
                Group {
                    if isPrimary {
                        Button(title, action: onAction)
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button(title, action: onAction)
                            .buttonStyle(.bordered)
                    }
                }
                .controlSize(.regular)
                // The label is load-bearing — it is what tells a denied row's button
                // WHERE it goes — so it must never be the thing that gets truncated.
                // Let the guidance text rewrap instead.
                .fixedSize()
            }
        }
    }

    /// A denied row's secondary line is an instruction, not background detail, so
    /// it comes forward from the reason line's opacity.
    private var guidanceColor: Color {
        switch status {
        case .denied, .needsRelaunch: return Color.white.opacity(0.62)
        case .needed, .granted: return Theme.textFaint
        }
    }
}

