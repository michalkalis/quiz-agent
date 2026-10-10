//
//  RoundCardRow.swift
//  Hangs
//
//  #198 (canvas R-Complete / Bg-Complete): the round as a row of small cards
//  beside "COMPLETE", one per question — a right answer in its card's colour,
//  a miss as a white card with a pink edge, a skip blank. Laid flat, not
//  fanned: the fan is kept for Home, Onboarding, Paywall and Sign-in (founder
//  2026-10-10). Static decoration; the score card says the same to VoiceOver.
//

import SwiftUI

struct RoundCardRow: View {
    enum Outcome {
        case correct(Theme.Hangs.Category.Style)
        case incorrect
        case skipped
    }

    let outcomes: [Outcome]

    private enum Metrics {
        static let cardWidth: CGFloat = 12
        static let minCardWidth: CGFloat = 4
        static let cardHeight: CGFloat = 18
        static let gap: CGFloat = 3
        static let corner: CGFloat = 3
        static let edge: CGFloat = 1.5
        /// The row never takes more than this from the headline beside it;
        /// a long round narrows its cards instead.
        static let maxWidth: CGFloat = 150
    }

    /// Full-size cards up to ten; a longer round narrows them to keep the row's width.
    private var cardWidth: CGFloat {
        let count = CGFloat(max(outcomes.count, 1))
        let fitting = (Metrics.maxWidth - Metrics.gap * (count - 1)) / count
        return max(Metrics.minCardWidth, min(Metrics.cardWidth, fitting))
    }

    var body: some View {
        HStack(spacing: Metrics.gap) {
            ForEach(outcomes.indices, id: \.self) { index in
                card(outcomes[index])
                    .frame(width: cardWidth, height: Metrics.cardHeight)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private func card(_ outcome: Outcome) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
        switch outcome {
        case let .correct(style):
            shape.fill(style.fill)
        case .incorrect:
            shape.fill(Theme.Hangs.Colors.bgCard)
                .overlay(shape.strokeBorder(Theme.Hangs.Colors.missText, lineWidth: Metrics.edge))
        case .skipped:
            shape.fill(Theme.Hangs.Colors.bgCard)
                .overlay(shape.strokeBorder(Theme.Hangs.Colors.track, lineWidth: Metrics.edge))
        }
    }
}

#if DEBUG
    #Preview {
        let cobalt = Theme.Hangs.Category.style(for: "geography-world")
        RoundCardRow(outcomes: [
            .correct(cobalt), .incorrect, .correct(cobalt), .skipped, .correct(cobalt),
            .incorrect, .correct(cobalt), .correct(cobalt), .correct(cobalt), .correct(cobalt),
        ])
        .padding(40)
        .background(Theme.Hangs.Colors.bg)
    }
#endif
