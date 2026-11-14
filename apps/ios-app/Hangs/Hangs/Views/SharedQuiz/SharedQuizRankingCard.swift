//
//  SharedQuizRankingCard.swift
//  Hangs
//
//  #232 (founder 2026-11-14, variant 4A): the comparison on the round end,
//  above the questions: rank, name, score, the viewer's own row tinted and
//  named "You". Who is listed is the server's choice (a friend sees only the
//  sender and themselves). With #232.2b each row also shows its ✓/✗ per
//  question; a server without the marks leaves them out.
//

import SwiftUI

struct SharedQuizRankingCard: View {
    private enum Metrics {
        static let rowHeight: CGFloat = 52
        static let rankWidth: CGFloat = 28
        static let markSide: CGFloat = 14
        static let markGlyph: CGFloat = 8
        static let markGap: CGFloat = 3
        static let markCorner: CGFloat = 4
    }

    let rows: [SharedQuizShareModel.Row]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xs) {
            HangsSectionLabel(text: "Ranking")
            HangsCard {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        if row.id != rows.first?.id { HangsDivider() }
                        rowView(row)
                    }
                }
            }
            Text("When others finish it, they show up here.")
                .font(.hangsBody)
                .foregroundStyle(Theme.Hangs.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("sharedQuiz.ranking")
    }

    private func rowView(_ row: SharedQuizShareModel.Row) -> some View {
        HStack(spacing: Theme.Hangs.Spacing.sm) {
            Text(verbatim: "\(row.rank).")
                .font(.hangsBody.monospacedDigit())
                .foregroundStyle(Theme.Hangs.Colors.muted)
                .frame(width: Metrics.rankWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
                name(row)
                    .font(.hangsLabel)
                    .foregroundStyle(Theme.Hangs.Colors.ink)
                    .lineLimit(1)
                if let marks = row.marks, !marks.isEmpty {
                    markStrip(marks)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: row.score)
                .font(.hangsHeading)
                .foregroundStyle(Theme.Hangs.Colors.ink)
        }
        .padding(.horizontal, Theme.Hangs.Spacing.md)
        .padding(.vertical, Theme.Hangs.Spacing.xs)
        .frame(minHeight: Metrics.rowHeight)
        .background(row.isYou ? Theme.Hangs.Colors.accentPrimarySoft : .clear)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func name(_ row: SharedQuizShareModel.Row) -> some View {
        if row.isYou {
            Text("You")
        } else {
            Text(verbatim: row.name)
        }
    }

    /// One small cell per question, the round end's cell language in miniature.
    private func markStrip(_ marks: [Bool?]) -> some View {
        HStack(spacing: Metrics.markGap) {
            ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                let shape = RoundedRectangle(cornerRadius: Metrics.markCorner, style: .continuous)
                Group {
                    switch mark {
                    case true?:
                        shape.fill(Theme.Hangs.Colors.action)
                            .overlay { glyph("checkmark", color: Theme.Hangs.Colors.textOnAction) }
                    case false?:
                        shape.strokeBorder(Theme.Hangs.Colors.mutedFaint, lineWidth: 1)
                            .overlay { glyph("xmark", color: Theme.Hangs.Colors.muted) }
                    case nil:
                        shape.strokeBorder(Theme.Hangs.Colors.mutedFaint, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    }
                }
                .frame(width: Metrics.markSide, height: Metrics.markSide)
            }
        }
        .accessibilityHidden(true)
    }

    private func glyph(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.hangsBody(Metrics.markGlyph, weight: .bold))
            .foregroundStyle(color)
    }
}
