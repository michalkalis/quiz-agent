//
//  ProfileStatTile.swift
//  Hangs
//
//  #213.4 (canvas "Lišta a Profil", Profil 1): one stat card in the Profile
//  grid. Unlocked: caption, value, one detail line. Locked: what is still
//  missing and a progress bar, on a dashed outline instead of a card.
//

import SwiftUI

struct ProfileStatTile: View {
    @Environment(\.locale) private var locale
    let card: StatCard

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
            if let caption = StatCardCopy.caption(card.kind) {
                Text(caption)
                    .font(.hangsCaption)
                    .foregroundStyle(Theme.Hangs.Colors.muted)
                    .lineLimit(2)
            }
            if let content = card.content {
                unlocked(content)
            } else {
                locked
            }
        }
        .padding(Theme.Hangs.Spacing.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("profile.card.\(card.kind)")
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Hangs.Radius.cardInner, style: .continuous)
        if card.isLocked {
            shape.strokeBorder(Theme.Hangs.Colors.subtleBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        } else {
            shape.fill(Theme.Hangs.Colors.bgCard)
        }
    }

    // MARK: - Unlocked

    @ViewBuilder
    private func unlocked(_ content: StatCardContent) -> some View {
        if let value = StatCardCopy.value(content, locale: locale) {
            HStack(spacing: Theme.Hangs.Spacing.xxs) {
                if let category = content.category {
                    Circle()
                        .fill(Theme.Hangs.Category.style(for: category).fill)
                        .frame(width: Metrics.dot, height: Metrics.dot)
                        .accessibilityHidden(true)
                }
                value
                    .font(.hangsLabel)
                    .foregroundStyle(valueColor(content))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        if let detail = StatCardCopy.detail(content) {
            detail
                .font(.hangsCaption)
                .foregroundStyle(Theme.Hangs.Colors.muted)
                .lineLimit(2)
        }
    }

    private func valueColor(_ content: StatCardContent) -> Color {
        if case .improvement(_, "up") = content { return Theme.Hangs.Colors.live }
        return Theme.Hangs.Colors.ink
    }

    // MARK: - Locked

    private var locked: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xs) {
            Text(ProfileStatTile.remaining(card.progress))
                .font(.hangsLabel)
                .foregroundStyle(Theme.Hangs.Colors.mutedFaint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HangsProgressBar(progress: card.progress.fraction, tint: Theme.Hangs.Colors.liveAccent)
        }
    }

    /// "2 more quizzes": what a locked card or the first recap still needs.
    static func remaining(_ progress: StatCard.Progress) -> LocalizedStringKey {
        let left = progress.remaining
        return switch progress.unit {
        case "games": "\(left) more quizzes"
        case "answers": "\(left) more questions"
        case "days": "\(left) more days of play"
        case "categories": "\(left) more categories"
        default: "Keep playing"
        }
    }

    private enum Metrics {
        /// The category colour dot before the name (canvas `.dot`).
        static let dot: CGFloat = 8
    }
}
