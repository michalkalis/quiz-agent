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
    /// Question numbers whose rows are open (#224.5); a snapshot starts some open.
    @State private var expanded: Set<Int>

    init(viewModel: RoomViewModel, expanded: Set<Int> = [], onShowPlans: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.viewModel = viewModel
        _expanded = State(initialValue: expanded)
        self.onShowPlans = onShowPlans
        self.onClose = onClose
    }

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
                    if !viewModel.roundSummaries.isEmpty {
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

    /// #224.5: every question with the right answer and one dot per player;
    /// a tap opens what each of them said.
    private var roundSummaries: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xs) {
            HangsSectionLabel(text: "Questions")
            HangsCard {
                VStack(spacing: 0) {
                    let rows = viewModel.roundSummaries
                    ForEach(rows) { row in
                        summaryRow(row)
                        if row.id != rows.last?.id { HangsDivider() }
                    }
                }
            }
        }
    }

    private func summaryRow(_ row: RoomViewModel.RoundSummary) -> some View {
        let isOpen = expanded.contains(row.number)
        return VStack(spacing: 0) {
            Button {
                withAnimation(.snappy) {
                    if isOpen { expanded.remove(row.number) } else { expanded.insert(row.number) }
                }
            } label: {
                HStack(spacing: Theme.Hangs.Spacing.sm) {
                    Text(verbatim: "\(row.number)")
                        .font(.hangsMonoValue)
                        .foregroundStyle(Theme.Hangs.Colors.muted)
                    VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
                        Text(verbatim: row.questionText)
                            .font(.hangsBody)
                            .foregroundStyle(Theme.Hangs.Colors.ink)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: row.correctAnswer ?? "")
                            .font(.hangsLabel)
                            .foregroundStyle(Theme.Hangs.Colors.ink)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: Metrics.dotGap) {
                        ForEach(row.rows) { player in
                            Circle()
                                .fill(player.isCorrect ? Theme.Hangs.Colors.greenCheck : Theme.Hangs.Colors.track)
                                .frame(width: Metrics.dot, height: Metrics.dot)
                        }
                    }
                    .accessibilityHidden(true)
                    Image(systemName: "chevron.down")
                        .font(.hangsCaption)
                        .foregroundStyle(Theme.Hangs.Colors.muted)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .padding(Theme.Hangs.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isOpen ? Text("expanded") : Text("collapsed"))
            .accessibilityIdentifier("room.final.round.\(row.number)")
            if isOpen {
                VStack(spacing: Theme.Hangs.Spacing.xs) {
                    ForEach(row.rows) { player in
                        HStack(spacing: Theme.Hangs.Spacing.sm) {
                            RoomPlayerAvatar(name: player.name, color: player.color, size: Metrics.face)
                            Text(verbatim: player.name)
                                .font(.hangsLabel)
                                .foregroundStyle(Theme.Hangs.Colors.ink)
                            Group {
                                if let answer = player.answer {
                                    Text(verbatim: answer)
                                } else {
                                    Text("no answer")
                                }
                            }
                            .font(.hangsCaption)
                            .foregroundStyle(Theme.Hangs.Colors.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if player.isCorrect {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Theme.Hangs.Colors.greenCheck)
                                    .accessibilityLabel(Text("correct"))
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.horizontal, Theme.Hangs.Spacing.md)
                .padding(.bottom, Theme.Hangs.Spacing.md)
                .accessibilityIdentifier("room.final.round.\(row.number).answers")
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
        static let dot: CGFloat = 8
        static let dotGap: CGFloat = 3
        static let face: CGFloat = 24
    }
}
