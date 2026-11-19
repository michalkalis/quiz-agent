//
//  RoomRankingShareImage.swift
//  Hangs
//
//  #240.9: the story-size picture "Share" sends from the end of a game
//  together: the winner, the ranking, the awards and the trubbo.app address,
//  on the winner's colour (same approach as the recap picture, #216.3).
//

import SwiftUI

struct RoomRankingShareImage: View {
    let ranks: [RoomViewModel.RankRow]
    let awards: [RoomViewModel.AwardRow]
    /// Questions in the game, for "2 of 3 correct".
    let total: Int

    var body: some View {
        let style = Theme.Hangs.Category.player(ranks.first?.color)
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.lg) {
            Text("Play together")
                .font(.hangsOverline)
                .textCase(.uppercase)
                .opacity(Metrics.captionOpacity)
            if let winner = ranks.first {
                VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
                    Text("Winner")
                        .font(.hangsMonoLabel)
                        .textCase(.uppercase)
                    Text(verbatim: winner.name)
                        .font(.hangsDisplaySM)
                        .hangsHeadlineFit()
                    Text("\(winner.correctCount) of \(total) correct")
                        .font(.hangsLabel)
                }
            }
            VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xs) {
                ForEach(ranks) { row in
                    HStack(spacing: Theme.Hangs.Spacing.sm) {
                        Text(verbatim: "\(row.rank).")
                            .font(.hangsMonoValue)
                            .opacity(Metrics.captionOpacity)
                        Text(verbatim: row.name)
                            .font(.hangsLabel)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(verbatim: "\(row.correctCount)")
                            .font(.hangsMonoValue)
                    }
                }
            }
            if !awards.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.sm) {
                    ForEach(awards) { row in
                        RoomAwardLine(row: row, textColor: style.text, captionColor: style.text.opacity(Metrics.captionOpacity))
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(alignment: .lastTextBaseline) {
                HangsBrandMark(size: Metrics.brand, color: style.text)
                Spacer(minLength: Theme.Hangs.Spacing.sm)
                Text(verbatim: "trubbo.app")
                    .font(.hangsLabel)
            }
        }
        .padding(.horizontal, Theme.Hangs.Spacing.xl)
        .padding(.vertical, Theme.Hangs.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(style.text)
        .background(style.fill)
    }

    private enum Metrics {
        static let brand: CGFloat = 20
        static let captionOpacity = 0.75
    }
}
