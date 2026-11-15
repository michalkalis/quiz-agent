//
//  OrderPackOptionButton.swift
//  Hangs
//
//  One choice in an order form button grid: difficulty (#224) and who the
//  pack is for (#236). Selected state matches `AnswerOption.selected` (action
//  fill, text on action).
//

import SwiftUI

struct OrderPackOptionButton: View {
    let title: LocalizedStringKey
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        // a11y-id: call-site
        Button(action: action) {
            Text(title)
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
    }

    private enum Metrics {
        static let minHeight: CGFloat = 52
    }
}
