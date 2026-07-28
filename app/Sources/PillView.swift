// PillView — the bottom-center capsule that is the ONLY chrome during a session.
// One surface, three states (countdown → recording → saved), translated from
// mockups/hotkey-ui/components/pill.tsx.

import AppKit
import SwiftUI

enum PillState: Equatable {
    /// Pre-roll. Names the target app so a wrong pick is catchable. Esc cancels.
    case countdown(remaining: Int, appName: String)
    /// Capturing. Red dot + elapsed + Stop.
    case recording(elapsed: TimeInterval)
    /// Confirmation flash, then fades.
    case saved(filename: String, duration: TimeInterval)
}

func formatClock(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    return String(format: "%d:%02d", total / 60, total % 60)
}

struct PillView: View {
    let state: PillState
    /// Debug instrument: draws the row's true vertical midline over the pill so
    /// optical centering can be *measured* in a screenshot instead of eyeballed.
    var showMidline: Bool = false
    /// Debug: hold animations at their resting phase so screenshots are deterministic.
    var freezeAnimation: Bool = false
    var onStop: () -> Void = {}

    var body: some View {
        HStack(alignment: .center, spacing: Theme.pillSpacing) {
            switch state {
            case let .countdown(remaining, appName):
                CountdownBadge(count: remaining)
                Text("Recording \(appName)…")
                    .font(Theme.labelFont)
                    .foregroundStyle(Theme.textSecondary)
                    .opticallyCentered(Theme.labelNSFont)
                HintRow(leading: nil, key: "esc", trailing: "cancel")

            case let .recording(elapsed):
                RecordingDot(freeze: freezeAnimation)
                Text(formatClock(elapsed))
                    .font(Theme.elapsedFont)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                    .opticallyCentered(Theme.elapsedNSFont)
                Rectangle()
                    .fill(Theme.divider)
                    .frame(width: 1, height: 14)
                    .pillRowItem()
                StopButton(action: onStop)
                HintRow(leading: "or", key: "esc", trailing: nil)

            case let .saved(filename, duration):
                SavedCheck()
                (
                    Text("Saved ").foregroundColor(Color.white.opacity(0.85))
                        + Text(filename).font(Theme.elapsedFont).foregroundColor(Color.white.opacity(0.5))
                        + Text(" · \(formatClock(duration))").foregroundColor(Color.white.opacity(0.40))
                )
                .font(Theme.labelFont)
                .opticallyCentered(Theme.labelNSFont)
            }
        }
        .padding(.horizontal, Theme.pillHPadding)
        .frame(height: Theme.pillHeight)
        .background(Capsule().fill(Theme.pillFill))
        .overlay(Capsule().strokeBorder(Theme.pillRing, lineWidth: 1))
        .overlay(alignment: .center) {
            if showMidline {
                Rectangle().fill(Color.green.opacity(0.9)).frame(height: 1)
            }
        }
        .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        .padding(Theme.pillShadowMargin)
        .fixedSize()
    }
}

// MARK: - Parts

private struct CountdownBadge: View {
    let count: Int
    private static let size: CGFloat = 20
    private static let digitSize: CGFloat = 11

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                .frame(width: Self.size, height: Self.size)
            Text("\(count)")
                .font(.system(size: Self.digitSize, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
                .opticallyCentered(
                    NSFont.systemFont(ofSize: Self.digitSize, weight: .semibold),
                    rowHeight: Self.size
                )
        }
        .pillRowItem()
    }
}

private struct RecordingDot: View {
    let freeze: Bool
    @State private var pulsing = false
    private static let size: CGFloat = 10

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.recordRed)
                .opacity(pulsing ? 0 : 0.55)
                .scaleEffect(pulsing ? 2.2 : 1)
            Circle().fill(Theme.recordRed)
        }
        .frame(width: Self.size, height: Self.size)
        .pillRowItem()
        .onAppear {
            guard !freeze else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                pulsing = true
            }
        }
    }
}

private struct StopButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(hovering ? 1 : 0.85))
                    .frame(width: 9, height: 9)
                    .pillRowItem()
                Text("Stop")
                    .font(Theme.labelFont)
                    .foregroundStyle(Color.white.opacity(hovering ? 1 : 0.85))
                    .opticallyCentered(Theme.labelNSFont)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pillRowItem()
    }
}

private struct SavedCheck: View {
    private static let size: CGFloat = 17

    var body: some View {
        ZStack {
            Circle().fill(Theme.savedGreen)
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.black)
        }
        .frame(width: Self.size, height: Self.size)
        .pillRowItem()
    }
}

/// `esc` chip with optional words on either side — "esc cancel" / "or esc".
private struct HintRow: View {
    let leading: String?
    let key: String
    let trailing: String?

    var body: some View {
        HStack(spacing: 5) {
            if let leading {
                Text(leading)
                    .font(Theme.hintFont)
                    .foregroundStyle(Theme.textMuted)
                    .opticallyCentered(Theme.hintNSFont)
            }
            Kbd(label: key)
            if let trailing {
                Text(trailing)
                    .font(Theme.hintFont)
                    .foregroundStyle(Theme.textMuted)
                    .opticallyCentered(Theme.hintNSFont)
            }
        }
        .pillRowItem()
    }
}

private struct Kbd: View {
    let label: String
    private static let chipHeight: CGFloat = 15

    var body: some View {
        Text(label)
            .font(Theme.kbdFont)
            .foregroundStyle(Theme.textFaint)
            .opticallyCentered(Theme.kbdNSFont, rowHeight: Self.chipHeight)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 3.5).fill(Theme.kbdFill))
            .overlay(RoundedRectangle(cornerRadius: 3.5).strokeBorder(Theme.kbdBorder, lineWidth: 1))
            .pillRowItem()
    }
}
