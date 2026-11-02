//
//  OrderPackDifficultyPicker.swift
//  Hangs
//
//  #224 (224.3): the required difficulty choice on the order form. Three equal
//  buttons and NO preselection — generated packs came out too easy when the
//  level was left to the model, so the buyer must pick one before the order
//  can continue. Selected state matches `AnswerOption.selected` (action fill,
//  text on action).
//

import SwiftUI

struct OrderPackDifficultyPicker: View {
    let selection: PackDifficulty?
    let onSelect: (PackDifficulty) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xs) {
            HangsSectionLabel(text: "Difficulty")
                .padding(.leading, Theme.Hangs.Spacing.md)
            HStack(spacing: Theme.Hangs.Spacing.xs) {
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
        let isSelected = selection == level
        return Button {
            onSelect(level)
        } label: {
            Text(level.label)
                .font(.hangsButton)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(isSelected ? Theme.Hangs.Colors.textOnAction : Theme.Hangs.Colors.ink)
                .frame(maxWidth: .infinity, minHeight: Metrics.minHeight)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Hangs.Radius.cardInner, style: .continuous)
                        .fill(isSelected ? Theme.Hangs.Colors.action : Theme.Hangs.Colors.bgCard)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Hangs.Radius.cardInner, style: .continuous)
                        .strokeBorder(Theme.Hangs.Colors.subtleBorder, lineWidth: isSelected ? 0 : 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("orderPack.difficulty.\(level.rawValue)")
    }

    private enum Metrics {
        static let minHeight: CGFloat = 52
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
