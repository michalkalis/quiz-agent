//
//  CompletionView.swift
//  Hangs
//
//  Quiz-Complete screen — NPlqf frame.
//  Editorial "COMPLETE" hero, final-score card, Correct/Incorrect/Accuracy
//  breakdown card, Play Again + Home CTA stack.
//  Display data sourced from QuizCompleteSummary (52.6); actions via viewModel.
//

import SwiftUI

struct CompletionView: View {
    @ObservedObject var viewModel: QuizViewModel

    var body: some View {
        VStack(spacing: 0) {
            HangsBrandRow {
                HangsNavChip(icon: "xmark") { viewModel.resetToHome() }
                    .accessibilityIdentifier("completion.close")
            }

            ScrollView {
                VStack(spacing: 0) {
                    HangsHeroBlock(
                        title: "COMPLETE",
                        subtitle: "nice work — here's your run",
                        titleFont: .hangsDisplayMD
                    )
                    .padding(.horizontal, 20)

                    finalScoreCard
                        .padding(.horizontal, 20)
                        .padding(.top, 12)

                    breakdownCard
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                }
                .padding(.bottom, 12)
            }

            Spacer(minLength: 0)

            ctaStack
        }
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
    }

    // MARK: - Final score card

    private var finalScoreCard: some View {
        HangsCard(padding: EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20)) {
            VStack(spacing: 6) {
                HangsSectionLabel(text: "final score", color: Theme.Hangs.Colors.pink)
                Text(summary.displayScore)
                    .font(.hangsNumberLG)
                    .tracking(-3)
                    .foregroundColor(Theme.Hangs.Colors.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(String(localized: "out of \(summary.totalQuestions)", comment: "Final-score caption: total number of questions"))
                    .font(.hangsBody(13, weight: .medium))
                    .foregroundColor(Theme.Hangs.Colors.muted)
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Final score: \(summary.displayScore) out of \(summary.totalQuestions)", comment: "Accessibility label for the final-score card"))
        .accessibilityIdentifier("completion.score")
    }

    // MARK: - Breakdown card

    private var breakdownCard: some View {
        HangsCard {
            VStack(spacing: 0) {
                breakdownRow(
                    label: "Correct",
                    value: "\(summary.correctCount)",
                    valueColor: Theme.Hangs.Colors.successText
                )
                Rectangle()
                    .fill(Theme.Hangs.Colors.hairline)
                    .frame(height: 1)
                breakdownRow(
                    label: "Incorrect",
                    value: "\(summary.incorrectCount)",
                    valueColor: Theme.Hangs.Colors.error
                )
                Rectangle()
                    .fill(Theme.Hangs.Colors.hairline)
                    .frame(height: 1)
                breakdownRow(
                    label: "Accuracy",
                    value: "\(Int(summary.sessionAccuracyPercent))%",
                    valueColor: Theme.Hangs.Colors.ink
                )
            }
        }
        .accessibilityIdentifier("completion.breakdown")
    }

    private func breakdownRow(label: LocalizedStringKey, value: String, valueColor: Color) -> some View {
        HStack {
            Text(label)
                .font(.hangsBody(16, weight: .semibold))
                .foregroundColor(Theme.Hangs.Colors.ink)
            Spacer()
            Text(value)
                .font(.hangsDisplay(28))
                .tracking(-1)
                .foregroundColor(valueColor)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - CTA stack

    private var ctaStack: some View {
        VStack(spacing: 8) {
            HangsPrimaryButton(
                title: "Play Again",
                icon: "arrow.counterclockwise",
                height: 58
            ) {
                Task { await viewModel.startNewQuiz() }
            }
            .accessibilityIdentifier("completion.playAgain")

            HangsSecondaryButton(
                title: "Home",
                icon: "house.fill",
                height: 52
            ) {
                viewModel.resetToHome()
            }
            .accessibilityIdentifier("completion.home")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    // MARK: - Derived

    /// Summary aggregated from viewModel state at .finished phase (52.6).
    var summary: QuizCompleteSummary {
        QuizCompleteSummary.from(
            score: viewModel.score,
            questionsAnswered: viewModel.questionsAnswered,
            correctCount: viewModel.sessionCorrectCount,
            incorrectCount: viewModel.sessionIncorrectCount,
            maxQuestions: viewModel.currentSession?.maxQuestions
                ?? viewModel.settings.numberOfQuestions,
            stats: viewModel.quizStats
        )
    }
}

#if DEBUG
    #Preview {
        let viewModel: QuizViewModel = {
            let vm = QuizViewModel.previewWithEvaluation
            vm.score = 8.5
            vm.questionsAnswered = 10
            vm.quizState = .finished
            return vm
        }()
        return CompletionView(viewModel: viewModel)
    }
#endif
