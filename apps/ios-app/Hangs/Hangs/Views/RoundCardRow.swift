//
//  RoundCardRow.swift
//  Hangs
//
//  #224 (canvas B4a): the round as a row of ten small cells under the score, one
//  per question, ONE colour: a right answer is a solid cell with a check, a miss
//  an outlined cell with a cross, a skip a dashed outline with a dash. Laid flat
//  in rows of up to ten. VoiceOver hears it as one element naming each
//  question's outcome in order; the score only has the counts.
//

import SwiftUI

struct RoundCardRow: View {
    enum Outcome {
        case correct
        case incorrect
        case skipped
    }

    let outcomes: [Outcome]

    private enum Metrics {
        static let perRow = 10
        static let cardHeight: CGFloat = 36
        static let gap: CGFloat = 5
        static let corner: CGFloat = 8
        static let edge: CGFloat = 1.5
        static let glyph: CGFloat = 13
        static let dash: [CGFloat] = [3, 3]
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
                return String(localized: "Question \(number), correct", bundle: .interface, locale: .interface, comment: "VoiceOver: one question of the finished round, answered right")
            case .incorrect:
                return String(localized: "Question \(number), incorrect", bundle: .interface, locale: .interface, comment: "VoiceOver: one question of the finished round, answered wrong or partly right")
            case .skipped:
                return String(localized: "Question \(number), skipped", bundle: .interface, locale: .interface, comment: "VoiceOver: one question of the finished round, skipped")
            }
        }
        .joined(separator: ". ")
    }

    @ViewBuilder private func card(_ outcome: Outcome) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
        switch outcome {
        case .correct:
            shape.fill(Theme.Hangs.Colors.action)
                .overlay { glyph("checkmark", color: Theme.Hangs.Colors.textOnAction) }
        case .incorrect:
            shape.strokeBorder(Theme.Hangs.Colors.mutedFaint, lineWidth: Metrics.edge)
                .overlay { glyph("xmark", color: Theme.Hangs.Colors.muted) }
        case .skipped:
            shape.strokeBorder(Theme.Hangs.Colors.mutedFaint, style: StrokeStyle(lineWidth: Metrics.edge, dash: Metrics.dash))
                .overlay { glyph("minus", color: Theme.Hangs.Colors.mutedFaint) }
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
        RoundCardRow(outcomes: (0 ..< 10).map { index in
            switch index {
            case 2, 6: .incorrect
            case 8: .skipped
            default: .correct
            }
        })
        .padding(16)
        .background(Theme.Hangs.Colors.bg)
    }
#endif
