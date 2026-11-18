//
//  OrderPackAudiencePicker.swift
//  Hangs
//
//  #236 (236.1): who the custom pack is written for. The same button grid as
//  the difficulty choice, but Adults is preselected, so it never holds the
//  order back. A content setting on the order, never a fact about the player.
//

import SwiftUI

struct OrderPackAudiencePicker: View {
    let selection: PackAudience
    let onSelect: (PackAudience) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xs) {
            HangsSectionLabel(text: "Who it's for")
                .padding(.leading, Theme.Hangs.Spacing.md)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Hangs.Spacing.xs), count: 2),
                spacing: Theme.Hangs.Spacing.xs
            ) {
                ForEach(PackAudience.allCases) { audience in
                    OrderPackOptionButton(title: audience.label, isSelected: selection == audience) {
                        onSelect(audience)
                    }
                    .accessibilityIdentifier("orderPack.audience.\(audience.rawValue)")
                }
            }
        }
    }
}

#if DEBUG
    #Preview {
        OrderPackAudiencePicker(selection: .adults, onSelect: { _ in })
            .padding(20)
            .background(Theme.Hangs.Colors.bg)
    }
#endif
