//
//  RoundCardRow.swift
//  Hangs
//
//  #198 (canvas Bg-Complete): the round as a row of cards under "COMPLETE",
//  one per question — a right answer in its card's colour with a check, a miss
//  as a white card with a pink edge and ✕, a skip blank with a dash. Laid flat
//  in rows of up to ten, not fanned: the fan is kept for Home, Onboarding,
//  Paywall and Sign-in (founder 2026-10-10). VoiceOver hears it as one element
//  naming each question's outcome in order; the score card only has the counts.
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
        static let perRow = 10
        static let cardHeight: CGFloat = 48
        static let gap: CGFloat = 6
        static let corner: CGFloat = 8
        static let edge: CGFloat = 2
        static let glyph: CGFloat = 13
    }

    /// Always ten slots, so a short round keeps card-shaped cards (leading).
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Metrics.gap), count: Metrics.perRow)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: Metrics.gap) {
            ForEach(outcomes.indices, id: \.self) { index in
                card(outcomes[index])
                    .frame(height: Metrics.cardHeight)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenOutcomes)
    }

    private var spokenOutcomes: String {
        outcomes.enumerated().map { index, outcome in
            let number = index + 1
            switch outcome {
            case .correct:
                return String(localized: "Question \(number), correct", comment: "VoiceOver: one question of the finished round, answered right")
            case .incorrect:
                return String(localized: "Question \(number), incorrect", comment: "VoiceOver: one question of the finished round, answered wrong or partly right")
            case .skipped:
                return String(localized: "Question \(number), skipped", comment: "VoiceOver: one question of the finished round, skipped")
            }
        }
        .joined(separator: ". ")
    }

    @ViewBuilder private func card(_ outcome: Outcome) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
        switch outcome {
        case let .correct(style):
            shape.fill(style.fill)
                .hangsShadow(Theme.Hangs.Shadow.card)
                .overlay { glyph("checkmark", color: style.text) }
        case .incorrect:
            shape.fill(Theme.Hangs.Colors.bgCard)
                .overlay(shape.strokeBorder(Theme.Hangs.Colors.missText, lineWidth: Metrics.edge))
                .overlay { glyph("xmark", color: Theme.Hangs.Colors.missText) }
        case .skipped:
            shape.fill(Theme.Hangs.Colors.bgCard)
                .overlay(shape.strokeBorder(Theme.Hangs.Colors.track, lineWidth: Metrics.edge))
                .overlay { glyph("minus", color: Theme.Hangs.Colors.muted) }
        }
    }

    private func glyph(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: Metrics.glyph, weight: .bold))
            .foregroundStyle(color)
    }
}

#if DEBUG
    #Preview {
        let ids = Theme.Hangs.Category.taxonomy
        RoundCardRow(outcomes: (0 ..< 10).map { index in
            switch index {
            case 2, 6: .incorrect
            case 8: .skipped
            default: .correct(Theme.Hangs.Category.style(for: ids[index % ids.count]))
            }
        })
        .padding(16)
        .background(Theme.Hangs.Colors.bg)
    }
#endif
