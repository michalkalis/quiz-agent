//
//  RoomQuestionView.swift
//  Hangs
//
//  #212: everyone's question screen: tap A–D or type, then the answer locks.
//  #224.4: faces and time on top, a calm drifting question card.
//  #249.4: the speaker and the host's pause are in the top bar, as in solo.
//  #249.5: solo's bar under the question carries the answer time, and a
//  typed-answer question gets solo's Answer (voice) and Type.
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
                    RoomPlayersStrip(players: viewModel.players, answered: Set(round.answered))
                    if viewModel.isPaused {
                        pausedLine
                    }
                    if let question = viewModel.question {
                        RoomQuestionCard(
                            question: question,
                            isHost: viewModel.isHost,
                            canReplay: viewModel.settings.readsAloud && !viewModel.isReadingAloud && !viewModel.isPaused,
                            hostIsReading: round.phase == .reading && !round.isPaused && !viewModel.guestReadsAloud,
                            replay: viewModel.readAgain
                        )
                        RoomListenBar(
                            phase: viewModel.listenPhase,
                            secondsLeft: viewModel.secondsLeft(),
                            showsMicOff: viewModel.micDenied && !question.isMultipleChoice
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
            RoomOpenAnswerControls(
                viewModel: viewModel,
                canAnswer: viewModel.canAnswer,
                canSpeak: viewModel.canSpeak,
                typing: $typing
            )
        }
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
                if !viewModel.answeredNames.isEmpty {
                    Text("Answered: \(viewModel.answeredNames.formatted(.list(type: .and, width: .narrow)))")
                        .font(.hangsCaption)
                        .foregroundStyle(Theme.Hangs.Colors.muted)
                        .accessibilityIdentifier("room.answer.answeredBy")
                }
            }
            .padding(Theme.Hangs.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("room.answer.locked")
    }

    /// #249.4: the host paused the question; its time stands still for
    /// everyone (the seconds in the bar under the question stop), answers still count.
    private var pausedLine: some View {
        Group {
            if viewModel.isHost {
                Label("Paused for everyone", systemImage: "pause.circle.fill")
            } else {
                Label("Paused by the host \(viewModel.host?.displayName ?? "")", systemImage: "pause.circle.fill")
            }
        }
        .font(.hangsLabel)
        .foregroundStyle(Theme.Hangs.Colors.ink)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("room.question.paused")
    }

    @ViewBuilder
    private func footer(_ round: RoomState.Round) -> some View {
        if viewModel.isGrading {
            // #240.9: everyone answered; the answers are being checked.
            Label {
                Text("Checking the answers…")
            } icon: {
                ProgressView()
            }
            .font(.hangsLabel)
            .foregroundStyle(Theme.Hangs.Colors.ink)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("room.question.grading")
        } else if round.yourAnswer == nil, viewModel.secondsLeft() == 0 {
            Text("Time's up")
                .font(.hangsLabel)
                .foregroundStyle(Theme.Hangs.Colors.muted)
                .accessibilityIdentifier("room.question.timeUp")
        } else if round.yourAnswer == nil, let note = viewModel.voiceNote {
            voiceNoteLine(note)
        } else if round.yourAnswer == nil {
            Text("The others see your answer after the question.")
                .font(.hangsCaption)
                .foregroundStyle(Theme.Hangs.Colors.muted)
        }
    }

    /// #249.5: why the last spoken answer did not count; the question is still open.
    private func voiceNoteLine(_ note: RoomViewModel.VoiceNote) -> some View {
        Group {
            switch note {
            case .didNotCatch: Text("Didn't catch that")
            case .notSent: Text("Your answer didn't go through. Try again or type it.")
            }
        }
        .font(.hangsLabel)
        .foregroundStyle(Theme.Hangs.Colors.warning)
        .accessibilityIdentifier("room.answer.voiceNote")
    }
}
