//
//  RoomQuestionView.swift
//  Hangs
//
//  #212: everyone's question screen: tap A–D or type, then the answer locks.
//  #224.4: faces and time on top, a calm drifting question card, no audio
//  controls for guests.
//

import SwiftUI

struct RoomQuestionView: View {
    @ObservedObject var viewModel: RoomViewModel
    @FocusState private var typing: Bool

    var body: some View {
        // The countdown and the answer controls follow the server's time left.
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            VStack(spacing: Theme.Hangs.Spacing.sm) {
                if let round = viewModel.round {
                    HangsQuizProgressHeader(current: round.number, total: viewModel.state?.maxQuestions ?? round.number)
                    RoomPlayersStrip(
                        players: viewModel.players,
                        answered: Set(round.answered),
                        secondsLeft: viewModel.secondsLeft(),
                        fullSeconds: viewModel.state?.thinkingSeconds
                    )
                    if let question = viewModel.question {
                        RoomQuestionCard(
                            question: question,
                            isHost: viewModel.isHost,
                            canReplay: viewModel.settings.readsAloud && !viewModel.isReadingAloud,
                            hostIsReading: round.phase == .reading && !viewModel.guestReadsAloud,
                            guestReadsAloud: viewModel.guestReadsAloud,
                            toggleGuestReadAloud: { Task { await viewModel.setGuestReadsAloud(!viewModel.guestReadsAloud) } },
                            replay: viewModel.readAgain
                        )
                        answerArea(question, round: round)
                    }
                    footer(round)
                }
            }
            .padding(.horizontal, Theme.Hangs.Spacing.md)
            .padding(.bottom, Theme.Hangs.Spacing.md)
        }
        .onChange(of: viewModel.round?.yourAnswer) { _, answer in
            if answer != nil { typing = false }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func answerArea(_ question: Question, round: RoomState.Round) -> some View {
        if let answer = viewModel.yourAnswerText, round.yourAnswer != nil {
            lockedCard(answer)
        } else if question.isMultipleChoice {
            MCQOptionPicker(
                options: question.sortedAnswerOptions,
                labels: question.optionLabels,
                onSelect: { key, _ in Task { await viewModel.submitOption(key: key) } },
                externalSelectedKey: .constant(viewModel.submittingAnswer),
                isSubmitting: viewModel.submittingAnswer != nil
            )
            .disabled(!viewModel.canAnswer)
        } else {
            typedAnswerField
        }
    }

    private var typedAnswerField: some View {
        HStack(spacing: Theme.Hangs.Spacing.xs) {
            TextField("Type your answer", text: $viewModel.typedAnswer)
                .font(.hangsBodyLG)
                .submitLabel(.send)
                .focused($typing)
                .onSubmit { Task { await viewModel.submitTypedAnswer() } }
                .limitLength($viewModel.typedAnswer, to: RoomViewModel.maxAnswerLength)
                .padding(Theme.Hangs.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Hangs.Radius.cardInner, style: .continuous)
                        .fill(Theme.Hangs.Colors.bgCard)
                )
                .accessibilityIdentifier("room.answer.field")
            Button {
                Task { await viewModel.submitTypedAnswer() }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.hangsBody(Metrics.sendIcon, weight: .bold))
                    .foregroundStyle(Theme.Hangs.Colors.textOnAction)
                    .frame(width: Metrics.sendSide, height: Metrics.sendSide)
                    .background(Circle().fill(Theme.Hangs.Colors.action))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(Text("Send answer"))
            .accessibilityIdentifier("room.answer.send")
        }
        .disabled(!viewModel.canAnswer)
    }

    private func lockedCard(_ answer: String) -> some View {
        HangsCard {
            VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
                Label("Answer locked", systemImage: "lock.fill")
                    .font(.hangsLabel)
                    .foregroundStyle(Theme.Hangs.Colors.ink)
                Text(verbatim: answer)
                    .font(.hangsBodyLG)
                    .foregroundStyle(Theme.Hangs.Colors.ink)
                Text("The others see it after the question.")
                    .font(.hangsCaption)
                    .foregroundStyle(Theme.Hangs.Colors.muted)
            }
            .padding(Theme.Hangs.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("room.answer.locked")
    }

    @ViewBuilder
    private func footer(_ round: RoomState.Round) -> some View {
        if round.yourAnswer == nil, viewModel.secondsLeft() == 0 {
            Text("Time's up")
                .font(.hangsLabel)
                .foregroundStyle(Theme.Hangs.Colors.muted)
                .accessibilityIdentifier("room.question.timeUp")
        } else if round.yourAnswer == nil {
            Text("The others see your answer after the question.")
                .font(.hangsCaption)
                .foregroundStyle(Theme.Hangs.Colors.muted)
        }
    }

    private enum Metrics {
        static let sendSide: CGFloat = 52
        static let sendIcon: CGFloat = 18
    }
}
