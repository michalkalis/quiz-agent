//
//  ResultView.swift
//  CarQuiz
//
//  Answer evaluation and feedback display matching Pencil design
//

import SwiftUI

struct ResultView: View {
    @ObservedObject var viewModel: QuizViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showEvaluation = false
    @State private var showQuitConfirmation = false
    @State private var showSourceWebView = false
    @State private var questionRating: Int = 0

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                // MARK: - Header Section
                // Drag indicator pill
                Capsule()
                    .fill(Theme.Colors.textSecondary.opacity(0.4))
                    .frame(width: 36, height: 5)
                    .padding(.top, Theme.Spacing.sm)
                    .accessibilityHidden(true)

                // Inline header: Q X/10 • Y pts | Close button
                HStack {
                    // Progress and score inline
                    if let session = viewModel.currentSession {
                        Text("Q \(viewModel.questionsAnswered)/\(session.maxQuestions)  •  \(Int(viewModel.score)) pts")
                            .font(.textMDMedium)
                            .foregroundColor(Theme.Colors.textSecondary)
                            .accessibilityLabel("Question \(viewModel.questionsAnswered) of \(session.maxQuestions), \(Int(viewModel.score)) points")
                    }

                    Spacer()

                    // Close button
                    Button {
                        showQuitConfirmation = true
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Theme.Colors.textSecondary)
                            .frame(width: 44, height: 44)
                            .background(Theme.Colors.bgCard)
                            .clipShape(Circle())
                    }
                    .accessibilityLabel("End quiz")
                    .accessibilityIdentifier("result.endQuiz")
                }
                .padding(.horizontal)

                // MARK: - Result Badge
                if let evaluation = viewModel.resultEvaluation {
                    VStack(spacing: Theme.Spacing.lg) {
                        if showEvaluation {
                            ResultBadge(
                                type: resultBadgeType(for: evaluation.result),
                                points: evaluation.points,
                                isMinimal: evaluation.result == .skipped || evaluation.result == .incorrect
                            )
                            .transition(.scale.combined(with: .opacity))
                        } else {
                            Text("Let's see...")
                                .font(.displayLG)
                                .foregroundColor(Theme.Colors.textSecondary)
                                .padding(.vertical, Theme.Spacing.xl)
                        }

                        // Image reveal (for image questions)
                        if let question = viewModel.resultQuestion,
                           question.hasImage,
                           let mediaUrl = question.mediaUrl,
                           let url = URL(string: mediaUrl),
                           showEvaluation {
                            AsyncImage(url: url) { phase in
                                if case .success(let image) = phase {
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(maxHeight: 200)
                                        .cornerRadius(Theme.Radius.lg)
                                }
                            }
                            .accessibilityLabel("Question image")
                            .padding(.horizontal)
                        }

                        // Answer comparison
                        VStack(spacing: Theme.Spacing.md) {
                            // User's answer
                            AnswerCard(
                                label: "Your Answer:",
                                answer: evaluation.userAnswer,
                                style: .neutral
                            )

                            // Correct answer (shown after evaluation)
                            if showEvaluation {
                                AnswerCard(
                                    label: "Correct Answer:",
                                    answer: evaluation.correctAnswer,
                                    style: .correct
                                )
                            }
                        }
                        .padding(.horizontal)

                        // Explanation card (educational context)
                        if showEvaluation,
                           let explanation = evaluation.explanation ?? viewModel.resultQuestion?.explanation {
                            ExplanationCard(explanation: explanation)
                                .padding(.horizontal)
                        }

                        // Source attribution section
                        if let sourceExcerpt = viewModel.resultQuestion?.sourceExcerpt,
                           viewModel.resultQuestion?.sourceUrl != nil,
                           showEvaluation {
                            SourceCard(
                                excerpt: sourceExcerpt,
                                onReadMore: { showSourceWebView = true }
                            )
                            .padding(.horizontal)
                        }
                    }
                } else {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(Theme.Colors.accentPrimary)
                        .padding(.vertical, Theme.Spacing.xxl)
                }

                // MARK: - Question Rating
                if showEvaluation {
                    QuestionRatingRow(rating: $questionRating) { rating in
                        viewModel.rateQuestion(rating)
                    }
                    .padding(.horizontal)
                }

                // Bottom spacer so content doesn't hide behind sticky bar
                Spacer()
                    .frame(height: Theme.Spacing.xxl + Theme.Spacing.xl)
            }
        }
        .background(Theme.Colors.bgPrimary)
        .safeAreaInset(edge: .bottom) {
            // MARK: - Sticky Bottom Bar
            StickyBottomBar(
                viewModel: viewModel,
                autoAdvanceCountdown: viewModel.autoAdvanceCountdown,
                autoAdvanceEnabled: viewModel.autoAdvanceEnabled,
                isPaused: viewModel.currentQuestionPaused
            )
        }
        .interactiveMinimize(
            isMinimized: $viewModel.isMinimized,
            canMinimize: viewModel.canMinimize
        )
        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.7), value: showEvaluation)
        .sensoryFeedback(resultHaptic, trigger: showEvaluation)
        .onAppear {
            showEvaluation = true
        }
        .confirmationDialog(
            "End Quiz?",
            isPresented: $showQuitConfirmation,
            titleVisibility: .visible
        ) {
            Button("End Quiz", role: .destructive) {
                Task {
                    await viewModel.endQuiz()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to quit? Your progress will be saved, but the current session will end.")
        }
        .sheet(isPresented: $showSourceWebView) {
            if let sourceUrl = viewModel.resultQuestion?.sourceUrl {
                SourceWebView(url: sourceUrl, isPresented: $showSourceWebView)
            }
        }
    }

    // MARK: - Helper Functions

    private var resultHaptic: SensoryFeedback {
        guard let evaluation = viewModel.resultEvaluation else { return .impact }
        switch evaluation.result {
        case .correct: return .success
        case .incorrect, .skipped: return .error
        case .partiallyCorrect, .partiallyIncorrect: return .warning
        }
    }

    private func resultBadgeType(for result: Evaluation.EvaluationResult) -> ResultBadge.ResultType {
        switch result {
        case .correct:
            return .correct
        case .incorrect:
            return .incorrect
        case .partiallyCorrect, .partiallyIncorrect:
            return .partiallyCorrect
        case .skipped:
            return .skipped
        }
    }
}

// MARK: - Sticky Bottom Bar

private struct StickyBottomBar: View {
    @ObservedObject var viewModel: QuizViewModel
    let autoAdvanceCountdown: Int
    let autoAdvanceEnabled: Bool
    let isPaused: Bool

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            // Auto-advance indicator above buttons
            if autoAdvanceEnabled && !isPaused {
                if autoAdvanceCountdown > 0 {
                    CountdownTimer(seconds: autoAdvanceCountdown)
                } else {
                    HStack(spacing: Theme.Spacing.xs) {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(Theme.Colors.accentPrimary)
                            .accessibilityHidden(true)
                        Text("Loading next question...")
                            .font(.textXS)
                            .foregroundColor(Theme.Colors.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Loading next question")
                }
            } else if isPaused {
                Text("Staying on this question")
                    .font(.textXS)
                    .foregroundColor(Theme.Colors.textSecondary)
                    .accessibilityLabel("Paused, staying on this question")
            }

            // Primary continue button
            PrimaryButton(title: continueTitle, icon: "arrow.right") {
                viewModel.continueToNext()
            }
            .accessibilityIdentifier("result.continue")

            // Stay Here secondary text button
            Button("Stay Here") {
                viewModel.pauseQuiz()
            }
            .accessibilityLabel("Stay Here")
            .accessibilityHint("Pause auto-advance and stay on this result")
            .accessibilityIdentifier("result.stayHere")
            .font(.textMDMedium)
            .foregroundColor(Theme.Colors.textSecondary)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .disabled(isPaused)
        }
        .padding(.horizontal)
        .padding(.top, Theme.Spacing.sm)
        .padding(.bottom, Theme.Spacing.xs)
        .background(
            Theme.Colors.bgPrimary
                .shadow(color: Theme.Shadows.elevationColor, radius: Theme.Shadows.elevationRadius, y: -Theme.Shadows.elevationY)
        )
    }

    private var continueTitle: String {
        if autoAdvanceEnabled && !isPaused && autoAdvanceCountdown > 0 {
            return "Continue (\(autoAdvanceCountdown)s)"
        }
        return "Continue"
    }
}

// MARK: - Answer Card Component

private struct AnswerCard: View {
    enum Style {
        case neutral
        case correct
    }

    let label: String
    let answer: String
    let style: Style

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(label)
                .font(.labelSM)
                .foregroundColor(Theme.Colors.textTertiary)
                .textCase(.uppercase)

            Text(answer)
                .font(.textMD)
                .foregroundColor(Theme.Colors.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.md)
        .background(backgroundColor)
        .cornerRadius(Theme.Radius.md)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(borderColor, lineWidth: 1.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(answer)")
    }

    private var backgroundColor: Color {
        switch style {
        case .neutral:
            return Theme.Colors.bgCard
        case .correct:
            return Theme.Colors.successBg
        }
    }

    private var borderColor: Color {
        switch style {
        case .neutral:
            return Theme.Colors.border
        case .correct:
            return Theme.Colors.success.opacity(0.3)
        }
    }
}

// MARK: - Source Card Component

private struct SourceCard: View {
    let excerpt: String
    let onReadMore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "link.circle.fill")
                    .foregroundColor(Theme.Colors.accentPrimary)
                Text("Source")
                    .font(.displayMD)
                    .foregroundColor(Theme.Colors.textPrimary)
            }

            Text(excerpt)
                .font(.textSM)
                .foregroundColor(Theme.Colors.textSecondary)
                .padding(Theme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Colors.accentPrimarySoft)
                .cornerRadius(Theme.Radius.sm)

            Button(action: onReadMore) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text("Read Full Article")
                    Image(systemName: "arrow.up.forward.circle")
                        .accessibilityHidden(true)
                }
                .font(.textSM)
                .foregroundColor(Theme.Colors.accentPrimary)
            }
            .accessibilityLabel("Read Full Article")
            .accessibilityHint("Opens the source article in a browser")
        }
        .padding(Theme.Spacing.md)
        .background(Theme.Colors.bgCard)
        .cornerRadius(Theme.Radius.md)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Source information")
    }
}

// MARK: - Explanation Card

private struct ExplanationCard: View {
    let explanation: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "lightbulb.fill")
                    .foregroundColor(Theme.Colors.warning)
                Text("Did You Know?")
                    .font(.displayMD)
                    .foregroundColor(Theme.Colors.textPrimary)
            }

            Text(explanation)
                .font(.textSM)
                .foregroundColor(Theme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.warningBg)
        .cornerRadius(Theme.Radius.md)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Did you know? \(explanation)")
    }
}

// MARK: - Question Rating Row

private struct QuestionRatingRow: View {
    @Binding var rating: Int
    let onRate: (Int) -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text("Rate this question:")
                .font(.textXS)
                .foregroundColor(Theme.Colors.textSecondary)

            HStack(spacing: 0) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        rating = star
                        onRate(star)
                    } label: {
                        Image(systemName: star <= rating ? "star.fill" : "star")
                            .font(.textMD)
                            .foregroundColor(star <= rating ? Theme.Colors.warning : Theme.Colors.textMuted)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("\(star) star\(star == 1 ? "" : "s")")
                    .accessibilityIdentifier("result.ratingStar.\(star)")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rate this question, \(rating > 0 ? "\(rating) of 5 stars" : "not rated")")
    }
}

#Preview {
    ResultView(viewModel: QuizViewModel.previewWithEvaluation)
}
