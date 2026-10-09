//
//  HomeCategoryDeck.swift
//  Hangs
//
//  #194 C1 — the Home card deck ("Sklo nad kartami", R-Home): the chosen
//  categories fanned behind a white front card that names the round. Pure
//  decoration of state the pills below already state, so it is hidden from
//  VoiceOver and dropped at accessibility text sizes (content first). Static —
//  motion belongs to card arrival in the quiz, not to Home.
//

import SwiftUI

struct HomeCategoryDeck: View {
    /// Selected category ids; empty = all categories.
    let selectedCategories: [String]
    /// The front card's title: the same value the Categories pill shows.
    let title: String
    let questionCount: Int

    var body: some View {
        ZStack {
            ForEach(Array(backCards.enumerated()), id: \.element) { index, id in
                backCard(id)
                    .rotationEffect(Metrics.fan[index].angle, anchor: .bottom)
                    .offset(x: Metrics.fan[index].offset)
            }
            frontCard
                .rotationEffect(Metrics.frontAngle, anchor: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }

    /// Three cards behind the front one: the selected categories nearest the
    /// front, topped up from the taxonomy so the fan always has three.
    private var backCards: [String] {
        let taxonomy = Theme.Hangs.Category.taxonomy
        let rest = Metrics.defaultFan.filter { !selectedCategories.contains($0) }
            + taxonomy.filter { !selectedCategories.contains($0) && !Metrics.defaultFan.contains($0) }
        let nearestFirst = Array((selectedCategories + rest).prefix(Metrics.fan.count))
        return nearestFirst.reversed()
    }

    private var stripCategories: [String] {
        selectedCategories.isEmpty ? Theme.Hangs.Category.taxonomy : selectedCategories
    }

    private func backCard(_ id: String) -> some View {
        let style = Theme.Hangs.Category.style(for: id)
        return Text(verbatim: Config.categoryDisplayName(for: id))
            .textCase(.uppercase)
            .font(.hangsOverline)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(style.text)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(Theme.Hangs.Spacing.lg)
            .deckCardShape(fill: style.fill)
    }

    private var frontCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(questionCount) questions")
                .font(.hangsCaption.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Spacer(minLength: Theme.Hangs.Spacing.xs)
            Text(verbatim: title)
                .font(.hangsTitle)
                .lineLimit(3)
                .minimumScaleFactor(0.6)
            Spacer(minLength: Theme.Hangs.Spacing.xs)
            HStack(spacing: 0) {
                ForEach(stripCategories, id: \.self) { id in
                    Theme.Hangs.Category.style(for: id).fill
                }
            }
            .frame(height: Metrics.stripHeight)
            .clipShape(Capsule())
        }
        .foregroundStyle(Theme.Hangs.Colors.ink)
        .padding(Theme.Hangs.Spacing.lg)
        .deckCardShape(fill: Theme.Hangs.Colors.bgCard)
    }

    private typealias Metrics = DeckMetrics
}

private enum DeckMetrics {
    /// Canvas card: 196 × 256, scaled down to the space Home has left.
    static let cardSize = CGSize(width: 196, height: 256)
    static let stripHeight: CGFloat = 8
    static let frontAngle = Angle.degrees(2)
    /// Back to front: the canvas fan (rotation about the bottom edge, x shift).
    static let fan: [(angle: Angle, offset: CGFloat)] = [
        (.degrees(-13), -14),
        (.degrees(11), 14),
        (.degrees(-4), 0),
    ]
    static let defaultFan = ["geography-world", "science-nature", "history"]
}

private extension View {
    /// One deck card: the canvas proportions, scaled to fit, on its fill with
    /// the raised shadow (on the plate only, so text stays crisp).
    func deckCardShape(fill: Color) -> some View {
        aspectRatio(DeckMetrics.cardSize, contentMode: .fit)
            .frame(maxWidth: DeckMetrics.cardSize.width, maxHeight: DeckMetrics.cardSize.height)
            .background(
                RoundedRectangle(cornerRadius: Theme.Hangs.Radius.cta, style: .continuous)
                    .fill(fill)
                    .hangsShadow(Theme.Hangs.Shadow.raised)
            )
    }
}

#if DEBUG
    #Preview {
        VStack {
            HomeCategoryDeck(selectedCategories: [], title: "All Categories", questionCount: 10)
            HomeCategoryDeck(selectedCategories: ["movies-music", "entertainment"], title: "2 selected", questionCount: 10)
        }
        .padding(16)
        .background(Theme.Hangs.Colors.bg)
    }
#endif
