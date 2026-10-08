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
                        titleFont: .hangsDisplayMD
                    )
                    .padding(.horizontal, Theme.Hangs.Spacing.lg)

                    finalScoreCard
                        .padding(.horizontal, Theme.Hangs.Spacing.lg)
                        .padding(.top, Theme.Hangs.Spacing.sm)

                    breakdownCard
                        .padding(.horizontal, Theme.Hangs.Spacing.lg)
                        .padding(.top, 14)

                    if let remaining = upsellRemaining {
                        upsellCard(remaining: remaining)
                            .padding(.horizontal, Theme.Hangs.Spacing.lg)
                            .padding(.top, 14)
                    }
                }
                .padding(.bottom, Theme.Hangs.Spacing.sm)
            }

            Spacer(minLength: 0)

            ctaStack
        }
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
        .task { await viewModel.refreshUsage() }
    }

    // MARK: - Final score card

    private var finalScoreCard: some View {
        HangsCard(padding: EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20)) {
            VStack(spacing: 6) {
                HangsSectionLabel(text: "final score")
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
                    valueColor: countColor(summary.correctCount, Theme.Hangs.Colors.successText)
                )
                Rectangle()
                    .fill(Theme.Hangs.Colors.hairline)
                    .frame(height: 1)
                breakdownRow(
                    label: "Incorrect",
                    value: "\(summary.incorrectCount)",
                    valueColor: countColor(summary.incorrectCount, Theme.Hangs.Colors.error)
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

    /// A zero is no news either way, so it stays neutral instead of a red
    /// "Incorrect 0" (#188 G14).
    private func countColor(_ count: Int, _ color: Color) -> Color {
        count > 0 ? color : Theme.Hangs.Colors.muted
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

    // MARK: - Upsell card (#94 third paywall touchpoint)

    /// Soft upsell shown at the highest-intent moment (just finished a quiz)
    /// when the free quota is nearly exhausted. Hidden for premium users and
    /// whenever quota data is missing. Internal (like `summary`) so tests can
    /// pin the visibility rule directly.
    var upsellRemaining: Int? {
        guard let usage = viewModel.usageInfo,
              !usage.isPremium,
              let remaining = usage.remaining,
              remaining <= 5 else { return nil }
        return remaining
    }

    private func upsellCard(remaining: Int) -> some View {
        Button {
            viewModel.presentPaywall(source: .completion)
        } label: {
            HangsCard(padding: EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18)) {
                HStack(spacing: Theme.Hangs.Spacing.sm) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Running low on free questions")
                            .font(.hangsBody(15, weight: .semibold))
                            .foregroundColor(Theme.Hangs.Colors.ink)
                        Text("^[\(remaining) free questions](inflect: true) left this month.")
                            .font(.hangsBody(12))
                            .foregroundColor(Theme.Hangs.Colors.muted)
                    }
                    Spacer()
                    Text("Go Unlimited")
                        .font(.hangsBody(13, weight: .bold))
                        .foregroundColor(Theme.Hangs.Colors.textOnAction)
                        .padding(.horizontal, Theme.Hangs.Spacing.sm)
                        .padding(.vertical, Theme.Hangs.Spacing.xs)
                        .background(Capsule().fill(Theme.Hangs.Colors.action))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("completion.upsell")
    }

    // MARK: - CTA stack

    private var ctaStack: some View {
        VStack(spacing: Theme.Hangs.Spacing.xs) {
            HangsPrimaryButton(
                title: "Play Again",
                icon: "arrow.counterclockwise",
                height: 58
            ) {
                // Tracked via `beginQuizStart` (registers under `.quizStart` in the
                // task bag), never a bare `Task { }`: an untracked start survives
                // `resetToHome()`'s `taskBag.cancelAll()` and keeps going, so a
                // "Play Again" then "Home" left an orphan runner that set
                // currentSession/currentQuestion and spoke question TTS on the Home
                // screen (#133 V15).
                viewModel.beginQuizStart()
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
        .padding(.horizontal, Theme.Hangs.Spacing.lg)
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
            vm.currentSession = QuizSession.preview(score: 8.5, answered: 10)
            vm.quizState = .finished
            return vm
        }()
        return CompletionView(viewModel: viewModel)
    }
#endif
