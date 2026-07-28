// Theme — the pill/picker design tokens, translated from mockups/hotkey-ui into
// native idiom. The mockup renders inside a scaled-down simulated desktop, so its
// raw px values aren't screen points; what carries over is proportion, hierarchy
// and color. Sizes here are chosen to read correctly at 1x on a Retina display.

import AppKit
import SwiftUI

enum Theme {
    // MARK: Pill metrics

    /// Content row height of the pill. Everything inside is laid out in a row of
    /// exactly this height so vertical centering is a single, checkable fact.
    static let pillHeight: CGFloat = 38
    static let pillHPadding: CGFloat = 15
    static let pillSpacing: CGFloat = 11
    /// Transparent margin baked into the window so the SwiftUI drop shadow has
    /// room to render inside the window bounds (the window itself casts none).
    static let pillShadowMargin: CGFloat = 26
    /// Distance from the bottom of the screen's visible frame, mockup's `bottom-[4%]`.
    static let pillBottomFraction: CGFloat = 0.04

    // MARK: Type

    static let labelSize: CGFloat = 13
    static let elapsedSize: CGFloat = 13
    static let hintSize: CGFloat = 11
    static let kbdSize: CGFloat = 10

    static let labelFont = Font.system(size: labelSize, weight: .medium)
    static let labelNSFont = NSFont.systemFont(ofSize: labelSize, weight: .medium)

    static let elapsedFont = Font.system(size: elapsedSize, weight: .medium, design: .monospaced)
    static let elapsedNSFont = NSFont.monospacedSystemFont(ofSize: elapsedSize, weight: .medium)

    static let hintFont = Font.system(size: hintSize, weight: .regular)
    static let hintNSFont = NSFont.systemFont(ofSize: hintSize, weight: .regular)

    static let kbdFont = Font.system(size: kbdSize, weight: .medium, design: .monospaced)
    static let kbdNSFont = NSFont.monospacedSystemFont(ofSize: kbdSize, weight: .medium)

    // MARK: Color

    /// rgba(12,12,14,0.94) — the near-black pill body.
    static let pillFill = Color(red: 12 / 255, green: 12 / 255, blue: 14 / 255).opacity(0.94)
    static let pillRing = Color.white.opacity(0.10)
    static let recordRed = Color(red: 239 / 255, green: 68 / 255, blue: 68 / 255) // tailwind red-500
    static let savedGreen = Color(red: 16 / 255, green: 185 / 255, blue: 129 / 255).opacity(0.9) // emerald-500/90

    static let textPrimary = Color.white.opacity(0.90)
    static let textSecondary = Color.white.opacity(0.80)
    static let textMuted = Color.white.opacity(0.38)
    static let textFaint = Color.white.opacity(0.50)

    static let kbdBorder = Color.white.opacity(0.15)
    static let kbdFill = Color.white.opacity(0.06)
    static let divider = Color.white.opacity(0.15)
}

// MARK: - Optical vertical centering

extension View {
    /// Center a text run by its INK (cap-height band), not by its layout box.
    ///
    /// SwiftUI centers `Text` by the line box, which is asymmetric — ascender +
    /// leading above, descender below — so text visibly rides high inside a pill.
    /// `ViewDimensions` exposes the real first baseline, so the ink midpoint is
    /// `baseline - capHeight/2`; publishing that as the view's `.center` guide and
    /// then pinning it into a fixed-height frame puts the ink on the row midline.
    ///
    /// Every child of the pill row gets the same fixed height, so the row's own
    /// centering can't reintroduce the asymmetry.
    func opticallyCentered(_ font: NSFont, rowHeight: CGFloat = Theme.pillHeight) -> some View {
        self
            .alignmentGuide(VerticalAlignment.center) { d in
                d[.firstTextBaseline] - font.capHeight / 2
            }
            .frame(height: rowHeight)
    }

    /// Non-text children (dots, chips, icons) are already symmetric about their box
    /// center — they just need the same row height so the HStack stays honest.
    func pillRowItem(rowHeight: CGFloat = Theme.pillHeight) -> some View {
        frame(height: rowHeight)
    }
}
