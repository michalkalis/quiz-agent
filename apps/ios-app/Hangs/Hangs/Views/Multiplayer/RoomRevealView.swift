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
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.md) {
                        if holdsResults {
                            heldCard
                        } else {
                            answerCard(round)
                            results(round)
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
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                RoomNextFooter(viewModel: viewModel)
            }
        }
        .padding(.horizontal, Theme.Hangs.Spacing.md)
        .padding(.bottom, Theme.Hangs.Spacing.md)
    }

    /// A–D: the options with who picked what. Typed: a line per player.
    @ViewBuilder
    private func results(_ round: RoomState.Round) -> some View {
        if let options = viewModel.optionRows(for: round) {
            RoomOptionRows(options: options)
            let silent = viewModel.revealRows(for: round).filter { $0.answer == nil }
            if !silent.isEmpty {
                HStack(spacing: Theme.Hangs.Spacing.xs) {
                    ForEach(silent) { RoomPlayerAvatar(name: $0.name, color: $0.color, size: 24) }
                    Text("No answer: \(silent.map(\.name).formatted(.list(type: .and, width: .narrow)))")
                }
                .font(.hangsCaption)
                .foregroundStyle(Theme.Hangs.Colors.muted)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("room.reveal.silent")
            }
        } else {
            RoomAnswerRows(rows: viewModel.revealRows(for: round))
        }
    }

    private func answerCard(_ round: RoomState.Round) -> some View {
        let identity = DeckIdentity(category: viewModel.question?.category, packId: nil)
        let typed = viewModel.optionRows(for: round) == nil
        return HangsDeckCard(style: identity.style, categoryName: identity.chipName) {
            VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.sm) {
                Text(verbatim: round.questionText)
                    .font(.hangsBody)
                    .fixedSize(horizontal: false, vertical: true)
                if typed {
                    Text("Correct answer")
                        .font(.hangsMonoLabel)
                        .textCase(.uppercase)
                    HangsAnswerSticker(text: round.correctAnswer ?? "")
                        .accessibilityIdentifier("room.reveal.answer")
                }
                Text("Correct: \(viewModel.correctCount(in: round))/\(viewModel.players.count)")
                    .font(.hangsLabel)
                    .accessibilityIdentifier("room.reveal.count")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
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
}

/// The host moves on (by itself after a countdown, unless it stays); a guest
/// waits for it and sees when the host paused (#224.4).
struct RoomNextFooter: View {
    @ObservedObject var viewModel: RoomViewModel

    var body: some View {
        if viewModel.isHost {
            HStack(spacing: Theme.Hangs.Spacing.xs) {
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
                .layoutPriority(1)
                if viewModel.isPaused {
                    HangsSecondaryButton(title: "Resume", icon: "play.fill", singleLineTitle: true) {
                        Task { await viewModel.togglePause() }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityIdentifier("room.resume")
                } else {
                    HangsSecondaryButton(title: "Stay", icon: "pause.fill", singleLineTitle: true) {
                        Task { await viewModel.togglePause() }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityIdentifier("room.pause")
                }
            }
        } else if viewModel.isPaused {
            Label("The host paused", systemImage: "pause.circle.fill")
                .font(.hangsLabel)
                .foregroundStyle(Theme.Hangs.Colors.ink)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("room.paused")
        } else {
            Text("The host moves on to the next question.")
                .font(.hangsCaption)
                .foregroundStyle(Theme.Hangs.Colors.muted)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("room.waitingForHost")
        }
    }
}
