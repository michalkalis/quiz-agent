//
//  OrderPackDifficultyPicker.swift
//  Hangs
//
//  #224 (224.3): the required difficulty choice on the order form. Four equal
//  buttons and NO preselection — generated packs came out too easy when the
//  level was left to the model, so the buyer must pick one before the order
//  can continue.
//

import SwiftUI

struct OrderPackDifficultyPicker: View {
    let selection: PackDifficulty?
    let onSelect: (PackDifficulty) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xs) {
            HangsSectionLabel(text: "Difficulty")
                .padding(.leading, Theme.Hangs.Spacing.md)
            // Two columns: four choices in one row get too tight for "Stredná" at
            // larger text sizes.
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Hangs.Spacing.xs), count: 2),
                spacing: Theme.Hangs.Spacing.xs
            ) {
                ForEach(PackDifficulty.allCases) { level in
                    option(level)
                }
            }
            if selection == nil {
                Text("Choose a difficulty to continue.")
                    .font(.hangsCaption)
                    .foregroundStyle(Theme.Hangs.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Theme.Hangs.Spacing.md)
                    .accessibilityIdentifier("orderPack.difficulty.hint")
            }
        }
    }

    private func option(_ level: PackDifficulty) -> some View {
        OrderPackOptionButton(title: level.label, isSelected: selection == level) {
            onSelect(level)
        }
        .accessibilityIdentifier("orderPack.difficulty.\(level.rawValue)")
    }
}

#if DEBUG
    #Preview {
        VStack(spacing: 24) {
            OrderPackDifficultyPicker(selection: nil, onSelect: { _ in })
            OrderPackDifficultyPicker(selection: .hard, onSelect: { _ in })
        }
        .padding(20)
        .background(Theme.Hangs.Colors.bg)
    }
#endif
