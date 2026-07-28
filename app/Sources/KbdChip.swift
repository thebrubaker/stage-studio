// Keyboard hint chips, shared by the pill and the picker.
//
// Rule: a key with a GLYPH on the physical keyboard (arrows, return) renders as
// an SF Symbol, so the whole set is drawn by one type family at one weight —
// mixed Unicode arrows are exactly the thing that reads wrong. A key that is a
// WORD on the keycap ("esc") renders as text, matching the keycap itself.

import AppKit
import SwiftUI

/// Word key — `esc`.
struct KbdKey: View {
    let text: String
    var size: CGFloat = Theme.kbdSize
    var chipHeight: CGFloat = Theme.kbdChipHeight
    var rowHeight: CGFloat = Theme.pillHeight

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .medium, design: .monospaced))
            .foregroundStyle(Theme.textFaint)
            .opticallyCentered(
                NSFont.monospacedSystemFont(ofSize: size, weight: .medium),
                rowHeight: chipHeight
            )
            .kbdChip(height: chipHeight, rowHeight: rowHeight)
    }
}

/// Glyph key(s) — one chip holding one or more SF Symbols, all at the same size
/// and weight so an arrow cluster reads as a single uniform set.
struct KbdGlyphs: View {
    let symbols: [String]
    var size: CGFloat = Theme.kbdGlyphSize
    var chipHeight: CGFloat = Theme.kbdChipHeight
    var rowHeight: CGFloat = Theme.pillHeight

    var body: some View {
        HStack(spacing: 4) {
            ForEach(symbols, id: \.self) { name in
                Image(systemName: name)
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(Theme.textFaint)
            }
        }
        .frame(height: chipHeight)
        .kbdChip(height: chipHeight, rowHeight: rowHeight)
    }
}

private extension View {
    func kbdChip(height: CGFloat, rowHeight: CGFloat) -> some View {
        self
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 3.5).fill(Theme.kbdFill))
            .overlay(RoundedRectangle(cornerRadius: 3.5).strokeBorder(Theme.kbdBorder, lineWidth: 1))
            .frame(height: rowHeight)
    }
}
