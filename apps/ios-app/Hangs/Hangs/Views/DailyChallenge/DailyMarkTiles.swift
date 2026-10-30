//
//  DailyMarkTiles.swift
//  Hangs
//
//  #205: the daily challenge's questions as a row of tiles — knew it (mint,
//  ✓), missed it (pink edge, ✕), or not answered yet (empty). On the Home
//  card before the day is played every tile is empty; after it, and on the
//  daily round end, they show the outcome. Never the answers themselves.
//

import SwiftUI

struct DailyMarkTiles: View {
    /// One per question in play order; nil = not answered.
    let marks: [Bool?]
    var tileHeight: CGFloat = Metrics.homeTileHeight

    enum Metrics {
        /// Design slots: compact on the Home card, larger on the round end.
        static let homeTileHeight: CGFloat = 36
        static let roundEndTileHeight: CGFloat = 56
        static let corner: CGFloat = 8
        static let edge: CGFloat = 2
        static let glyph: CGFloat = 14
    }

    var body: some View {
        HStack(spacing: Theme.Hangs.Spacing.xs) {
            ForEach(marks.indices, id: \.self) { index in
                tile(marks[index])
                    .frame(maxWidth: .infinity)
                    .frame(height: tileHeight)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenMarks)
    }

    private var spokenMarks: String {
        marks.enumerated().map { index, mark in
            let number = index + 1
            return switch mark {
            case true?: String(localized: "Question \(number), correct", bundle: .interface, locale: .interface, comment: "VoiceOver: one question of the finished round, answered right")
            case false?: String(localized: "Question \(number), incorrect", bundle: .interface, locale: .interface, comment: "VoiceOver: one question of the finished round, answered wrong or partly right")
            case nil: String(localized: "Question \(number), not answered", bundle: .interface, locale: .interface, comment: "VoiceOver: one question of the daily challenge, not answered yet")
            }
        }
        .joined(separator: ". ")
    }

    @ViewBuilder private func tile(_ mark: Bool?) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
        switch mark {
        case true?:
            shape.fill(Theme.Hangs.Category.correct.fill)
                .overlay { glyph("checkmark", color: Theme.Hangs.Category.correct.text) }
        case false?:
            shape.fill(Theme.Hangs.Colors.bgCard)
                .overlay(shape.strokeBorder(Theme.Hangs.Colors.missText, lineWidth: Metrics.edge))
                .overlay { glyph("xmark", color: Theme.Hangs.Colors.missText) }
        case nil:
            shape.fill(Theme.Hangs.Colors.bgInset)
                .overlay(shape.strokeBorder(Theme.Hangs.Colors.track, lineWidth: Metrics.edge))
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
        VStack(spacing: 16) {
            DailyMarkTiles(marks: [nil, nil, nil, nil, nil])
            DailyMarkTiles(marks: [true, true, false, true, true], tileHeight: DailyMarkTiles.Metrics.roundEndTileHeight)
        }
        .padding(16)
        .background(Theme.Hangs.Colors.bg)
    }
#endif
