//
//  RoomFinalView.swift
//  Hangs
//
//  #212: the end of a game together: the ranking, and for the host who left
//  the app during a question. In round-reveal mode every question's answer.
//

import SwiftUI

struct RoomFinalView: View {
    @ObservedObject var viewModel: RoomViewModel
    let onShowPlans: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: Theme.Hangs.Spacing.md) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.md) {
                    if let winner = viewModel.rankRows.first {
                        winnerCard(winner)
                    }
                    ranking
                    if viewModel.isHost, !viewModel.awayRows.isEmpty {
                        awayNote
                    }
                    if viewModel.state?.revealMode == .round, !viewModel.roundSummaries.isEmpty {
                        roundSummaries
                    }
                    if viewModel.isHost, viewModel.quotaReached {
                        quotaNote
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            HangsPrimaryButton(title: "Done", action: onClose)
                .accessibilityIdentifier("room.done")
        }
        .padding(.horizontal, Theme.Hangs.Spacing.md)
        .padding(.bottom, Theme.Hangs.Spacing.md)
    }

    private func winnerCard(_ winner: RoomViewModel.RankRow) -> some View {
        let style = Theme.Hangs.Category.player(winner.color)
        return VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xs) {
            Text("Winner")
                .font(.hangsMonoLabel)
                .textCase(.uppercase)
            Text(verbatim: winner.name)
                .font(.hangsDisplaySM)
                .hangsHeadlineFit()
                .accessibilityIdentifier("room.final.winner")
            Text("\(winner.correctCount) of \(viewModel.state?.maxQuestions ?? 0) correct")
                .font(.hangsLabel)
        }
        .foregroundStyle(style.text)
        .padding(Theme.Hangs.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Hangs.Radius.deck, style: .continuous)
                .fill(style.fill)
        )
    }

    private var ranking: some View {
        HangsCard {
            VStack(spacing: 0) {
                let rows = viewModel.rankRows
                ForEach(rows) { row in
                    HStack(spacing: Theme.Hangs.Spacing.sm) {
                        Text(verbatim: "\(row.rank).")
                            .font(.hangsMonoValue)
                            .foregroundStyle(Theme.Hangs.Colors.muted)
                        RoomPlayerAvatar(name: row.name, color: row.color, size: 28)
                        Group {
                            if row.isYou {
                                Text("\(row.name) (you)")
                            } else {
                                Text(verbatim: row.name)
                            }
                        }
                        .font(.hangsLabel)
                        .foregroundStyle(Theme.Hangs.Colors.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(verbatim: "\(row.correctCount)")
                            .font(.hangsMonoValue)
                            .foregroundStyle(Theme.Hangs.Colors.ink)
                    }
                    .padding(.horizontal, Theme.Hangs.Spacing.md)
                    .frame(minHeight: Metrics.rowHeight)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("room.final.rank.\(row.rank)")
                    if row.id != rows.last?.id { HangsDivider() }
                }
            }
        }
    }

    /// #212.4: only the host sees it, and only now. No points were taken.
    private var awayNote: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
            ForEach(viewModel.awayRows) { row in
                Text(verbatim: "\(row.name): ") + Text("left Trubbo during \(row.questions) questions")
            }
            Text("Only you see this.")
                .foregroundStyle(Theme.Hangs.Colors.muted)
        }
        .font(.hangsCaption)
        .foregroundStyle(Theme.Hangs.Colors.ink)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("room.final.away")
    }

    private var roundSummaries: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xs) {
            HangsSectionLabel(text: "Answers")
            HangsCard {
                VStack(spacing: 0) {
                    let rows = viewModel.roundSummaries
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
                            Text(verbatim: "\(row.number). \(row.questionText)")
                                .font(.hangsBody)
                                .foregroundStyle(Theme.Hangs.Colors.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(verbatim: row.correctAnswer ?? "")
                                .font(.hangsLabel)
                                .foregroundStyle(Theme.Hangs.Colors.ink)
                            if let yours = row.yourAnswer {
                                Label {
                                    Text("You: \(yours)")
                                } icon: {
                                    Image(systemName: row.youWereRight ? "checkmark" : "xmark")
                                }
                                .font(.hangsCaption)
                                .foregroundStyle(row.youWereRight ? Theme.Hangs.Colors.greenCheck : Theme.Hangs.Colors.muted)
                            }
                        }
                        .padding(Theme.Hangs.Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("room.final.round.\(row.number)")
                        if row.id != rows.last?.id { HangsDivider() }
                    }
                }
            }
        }
    }

    private var quotaNote: some View {
        HangsCard {
            VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xs) {
                Text("Your free questions for this month are used up, so the game ended early.")
                    .font(.hangsBody)
                    .foregroundStyle(Theme.Hangs.Colors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HangsGhostButton(title: "Get Trubbo Plus", action: onShowPlans)
                    .accessibilityIdentifier("room.final.plans")
            }
            .padding(Theme.Hangs.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private enum Metrics {
        static let rowHeight: CGFloat = 52
    }
}
