// PickerView — the centered "record a window" panel summoned by ⌥⌘R.
// Translated from mockups/hotkey-ui/components/picker.tsx into native materials:
// a real NSVisualEffectView behind the panel, real app icons from NSWorkspace,
// and SF Symbols for the keyboard glyphs.

import AppKit
import SwiftUI

@MainActor
final class PickerModel: ObservableObject {
    @Published var windows: [CapturableWindow] = []
    @Published var thumbnails: [CGWindowID: CGImage] = [:]
    @Published var selected: Int = 0
    /// Shown in place of the footer hints when Screen Recording hasn't been
    /// granted — the picker still lists windows, it just can't preview them.
    @Published var notice: String?
}

struct PickerView: View {
    @ObservedObject var model: PickerModel
    var onPick: (CapturableWindow) -> Void
    var onClose: () -> Void

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: Theme.pickerGridGap),
            count: Theme.pickerColumns
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            grid
            footer
        }
        .frame(width: Theme.pickerWidth)
        .background(VisualEffectBackground(material: .hudWindow))
        .background(Theme.pickerTint)
        .clipShape(RoundedRectangle(cornerRadius: Theme.pickerCorner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.pickerCorner, style: .continuous)
                .strokeBorder(Theme.pickerBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.55), radius: 30, y: 12)
        .padding(Theme.pickerShadowMargin)
        .fixedSize()
    }

    private var header: some View {
        HStack {
            Text("Record a window")
                .font(.system(size: 11, weight: .medium))
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(Color.white.opacity(0.40))
            Spacer()
            Text("windowclip")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.25))
        }
        .padding(.horizontal, 16)
        .padding(.top, 13)
        .padding(.bottom, 4)
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: Theme.pickerGridGap) {
                    ForEach(Array(model.windows.enumerated()), id: \.element.id) { index, window in
                        PickerCell(
                            window: window,
                            thumbnail: model.thumbnails[window.id],
                            isSelected: index == model.selected
                        )
                        .id(window.id)
                        .onTapGesture { onPick(window) }
                        .onHover { if $0 { model.selected = index } }
                    }
                }
                .padding(Theme.pickerPadding)
            }
            .frame(maxHeight: Theme.pickerGridMaxHeight)
            .scrollIndicators(.never)
            // Arrow keys must be able to reach windows below the fold, so the
            // grid follows the selection instead of stranding it off-screen.
            .onChange(of: model.selected) { _, index in
                guard model.windows.indices.contains(index) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(model.windows[index].id, anchor: .center)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if let notice = model.notice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.orange.opacity(0.75))
            } else {
                HStack(spacing: 16) {
                    hint(
                        KbdGlyphs(
                            symbols: ["arrow.left", "arrow.right", "arrow.up", "arrow.down"],
                            rowHeight: 18
                        ),
                        "navigate"
                    )
                    hint(KbdGlyphs(symbols: ["return"], rowHeight: 18), "record")
                }
            }
            Spacer()
            hint(KbdKey(text: "esc", rowHeight: 18), "close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.pickerFooterRule).frame(height: 1)
        }
    }

    private func hint(_ chip: some View, _ label: String) -> some View {
        HStack(spacing: 6) {
            chip
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.32))
                .opticallyCentered(NSFont.systemFont(ofSize: 11), rowHeight: 18)
        }
    }
}

// MARK: - Cell

private struct PickerCell: View {
    let window: CapturableWindow
    let thumbnail: CGImage?
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            thumb
            label
        }
        .padding(Theme.pickerCellPadding)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Theme.pickerSelectedFill : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Theme.pickerAccent : Color.clear, lineWidth: 2)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// The aspect ratio is carried by a plain Color, and the artwork rides in an
    /// `.overlay` — an overlay can't influence its parent's size, so every cell in
    /// a row comes out exactly the same height regardless of the source window's
    /// own proportions.
    private var thumb: some View {
        Color.black.opacity(0.35)
            .aspectRatio(Theme.pickerThumbAspect, contentMode: .fit)
            .overlay {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if let icon = window.icon {
                    // Placeholder while SCK is still working (or has been
                    // refused): the app's own icon, dimmed. Honest about being
                    // a stand-in rather than faking a preview.
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 34, height: 34)
                        .opacity(0.30)
                }
            }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private var label: some View {
        HStack(spacing: 7) {
            Group {
                if let icon = window.icon {
                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.12))
                }
            }
            .frame(width: Theme.pickerIconSize, height: Theme.pickerIconSize)

            VStack(alignment: .leading, spacing: 1) {
                Text(window.app)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(window.subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 1)
        .frame(height: Theme.pickerLabelHeight)
    }
}

// MARK: - Material

/// The real macOS blur behind the panel — `.hudWindow` is the dark, floating
/// material the mockup's backdrop-blur was approximating.
struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .vibrantDark)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
