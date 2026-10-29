//
//  RoomRevealView.swift
//  Hangs
//
//  #212: after a question closed: the right answer and what everyone said
//  (per-question reveal), or only "locked in" when results wait for the end.
//

import SwiftUI

struct RoomRevealView: View {
    @ObservedObject var viewModel: RoomViewModel
    /// Round-reveal mode: results come on the final screen.
    let holdsResults: Bool

    var body: some View {
        VStack(spacing: Theme.Hangs.Spacing.sm) {
            if let round = viewModel.round {
                HangsQuizProgressHeader(current: round.number, total: viewModel.state?.maxQuestions ?? round.number)
                // Outside the scroll view, so its shadow is not cut off.
                if !holdsResults { answerCard(round).fixedSize(horizontal: false, vertical: true) }
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.md) {
                        if holdsResults {
                            heldCard
                        } else {
                            resultsList(round)
                            if let explanation = round.explanation, !explanation.isEmpty {
                                VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
                                    HangsSectionLabel(text: "Why")
                                    Text(explanation)
                                        .font(.hangsBody)
                                        .foregroundStyle(Theme.Hangs.Colors.ink)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                RoomNextFooter(viewModel: viewModel)
            }
        }
        .padding(.horizontal, Theme.Hangs.Spacing.md)
        .padding(.bottom, Theme.Hangs.Spacing.md)
    }

    private func answerCard(_ round: RoomState.Round) -> some View {
        let identity = DeckIdentity(category: viewModel.question?.category, packId: nil)
        return HangsDeckCard(style: identity.style, categoryName: identity.chipName) {
            VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.sm) {
                Text(verbatim: round.questionText)
                    .font(.hangsBody)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Correct answer")
                    .font(.hangsMonoLabel)
                    .textCase(.uppercase)
                HangsAnswerSticker(text: round.correctAnswer ?? "")
                    .accessibilityIdentifier("room.reveal.answer")
                Text("Correct: \(viewModel.correctCount(in: round))/\(viewModel.players.count)")
                    .font(.hangsLabel)
                    .accessibilityIdentifier("room.reveal.count")
            }
        }
    }

    private func resultsList(_ round: RoomState.Round) -> some View {
        HangsCard {
            VStack(spacing: 0) {
                let rows = viewModel.revealRows(for: round)
                ForEach(rows) { row in
                    HStack(spacing: Theme.Hangs.Spacing.sm) {
                        RoomPlayerAvatar(name: row.name, color: row.color, size: 28)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: row.name)
                                .font(.hangsLabel)
                                .foregroundStyle(Theme.Hangs.Colors.ink)
                            if let answer = row.answer {
                                Text(verbatim: answer)
                                    .font(.hangsCaption)
                                    .foregroundStyle(Theme.Hangs.Colors.muted)
                            } else {
                                Text("no answer")
                                    .font(.hangsCaption)
                                    .foregroundStyle(Theme.Hangs.Colors.muted)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: row.isCorrect ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(row.isCorrect ? Theme.Hangs.Colors.greenCheck : Theme.Hangs.Colors.muted)
                            .accessibilityLabel(row.isCorrect ? Text("correct") : Text("incorrect"))
                    }
                    .padding(.horizontal, Theme.Hangs.Spacing.md)
                    .frame(minHeight: Metrics.rowHeight)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("room.reveal.row.\(row.id)")
                    if row.id != rows.last?.id { HangsDivider() }
                }
            }
        }
    }

    private var heldCard: some View {
        HangsCard {
            VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xs) {
                Label("Question closed", systemImage: "lock.fill")
                    .font(.hangsLabel)
                if let answer = viewModel.yourAnswerText {
                    Text("Your answer: \(answer)")
                        .font(.hangsBodyLG)
                } else {
                    Text("No answer in time.")
                        .font(.hangsBodyLG)
                }
                Text("Everyone sees the answers at the end of the game.")
                    .font(.hangsCaption)
                    .foregroundStyle(Theme.Hangs.Colors.muted)
            }
            .foregroundStyle(Theme.Hangs.Colors.ink)
            .padding(Theme.Hangs.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("room.reveal.held")
    }

    private enum Metrics {
        static let rowHeight: CGFloat = 52
    }
}

/// The host moves on (by itself after a countdown); a guest waits for it.
struct RoomNextFooter: View {
    @ObservedObject var viewModel: RoomViewModel

    var body: some View {
        if viewModel.isHost {
            HangsPrimaryButton(
                title: "Next",
                trailingIcon: "arrow.right",
                isLoading: viewModel.isWorking,
                countdownSecondsRemaining: viewModel.autoAdvanceLeft,
                countdownTotal: viewModel.autoAdvanceSeconds
            ) {
                Task { await viewModel.next() }
            }
            .disabled(viewModel.isWorking)
            .accessibilityIdentifier("room.next")
        } else {
            Text("The host moves on to the next question.")
                .font(.hangsCaption)
                .foregroundStyle(Theme.Hangs.Colors.muted)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("room.waitingForHost")
        }
    }
}
