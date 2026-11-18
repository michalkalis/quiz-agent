//
//  RecapShareImage.swift
//  Hangs
//
//  #216.3: the story-size picture the recap card shares.
//

import SwiftUI

/// The picture Share sends: the same three numbers at story size, with the
/// wordmark at the bottom.
struct RecapShareImage: View {
    @Environment(\.locale) private var locale
    let recap: PlayerRecap
    let rows: [StatCard]
    let style: Theme.Hangs.Category.Style

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.lg) {
            Spacer(minLength: 0)
            RecapCopy.title(recap, locale: locale)
                .font(.hangsOverline)
                .textCase(.uppercase)
                .opacity(RecapNumberRow.captionOpacity)
            ForEach(rows, id: \.kind) { card in
                RecapNumberRow(card: card, valueFont: .hangsTitle)
            }
            Spacer(minLength: 0)
            HangsBrandMark(size: Metrics.brand, color: style.text)
        }
        .padding(.horizontal, Theme.Hangs.Spacing.xl)
        .padding(.vertical, Theme.Hangs.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .foregroundStyle(style.text)
        .background(style.fill)
    }

    private enum Metrics {
        static let brand: CGFloat = 20
    }
}
