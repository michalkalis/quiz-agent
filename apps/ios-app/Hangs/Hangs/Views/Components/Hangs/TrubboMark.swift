//
//  TrubboMark.swift
//  Hangs
//
//  The logo mark: the Trubbo mascot, a flat orangutan head (founder 2026-10-13,
//  canvas "Trubbo refresh", Kolo 6). Replaces the #194 question mark with a
//  card-wave dot. A vector PDF generated from `docs/design/brand/trubbo-mascot.svg`
//  (`scripts/brand/mascot_assets.py`), the same artwork as the app icon layers.
//

import SwiftUI

struct TrubboMark: View {
    /// Height of the mark; the width follows the head's proportions.
    var height: CGFloat = 30

    var body: some View {
        Image(decorative: "TrubboMascot")
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .accessibilityHidden(true)
    }
}

#if DEBUG
    #Preview {
        HStack(spacing: 24) {
            TrubboMark(height: 30)
            TrubboMark(height: 80)
        }
        .padding(24)
        .background(Theme.Hangs.Colors.bg)
    }
#endif
