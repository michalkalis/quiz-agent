//
//  PackMiniDeck.swift
//  Hangs
//
//  #194 C8 — a custom pack drawn as a small deck: two cards behind an ink
//  front card that carries a count (canvas Dec-Now-Packs, Bg-PackGenerating).
//  Custom packs are ink, like their question cards. Decoration only.
//

import SwiftUI

struct PackMiniDeck: View {
    enum Size {
        case row, hero

        var card: CGSize {
            switch self {
            case .row: CGSize(width: 64, height: 84)
            case .hero: CGSize(width: 120, height: 156)
            }
        }

        var font: Font {
            switch self {
            case .row: .hangsHeading
            case .hero: .hangsDisplaySM
            }
        }
    }

    let label: String
    var size: Size = .row

    var body: some View {
        let style = Theme.Hangs.Category.style(for: nil)
        ZStack(alignment: .bottomLeading) {
            card(style.fill.opacity(0.55))
                .rotationEffect(.degrees(-8))
                .offset(x: -size.card.width / 10)
            card(style.fill.opacity(0.75))
                .rotationEffect(.degrees(5))
                .offset(x: size.card.width / 12)
            card(style.fill)
            Text(verbatim: label)
                .font(size.font.monospacedDigit())
                .foregroundStyle(style.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(Theme.Hangs.Spacing.xs)
        }
        .frame(width: size.card.width, height: size.card.height)
        .accessibilityHidden(true)
    }

    private func card(_ fill: Color) -> some View {
        RoundedRectangle(cornerRadius: Theme.Hangs.Radius.chip, style: .continuous)
            .fill(fill)
    }
}

/// Ready questions out of ordered, one segment per question (canvas
/// Bg-PackGenerating).
struct PackReadySegments: View {
    let ready: Int
    let total: Int

    var body: some View {
        HStack(spacing: Metrics.gap) {
            ForEach(0 ..< max(total, 0), id: \.self) { index in
                Capsule()
                    .fill(index < ready ? Theme.Hangs.Colors.accentPrimary : Theme.Hangs.Colors.track)
            }
        }
        .frame(height: Metrics.height)
        .accessibilityHidden(true)
    }

    private enum Metrics {
        static let gap: CGFloat = 3
        static let height: CGFloat = 8
    }
}
