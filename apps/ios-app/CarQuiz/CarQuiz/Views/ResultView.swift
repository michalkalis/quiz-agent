//
//  ResultView.swift
//  CarQuiz
//
//  Answer evaluation and feedback display matching Pencil design
//

import SwiftUI

struct ResultView: View {
    @ObservedObject var viewModel: QuizViewModel

    @State private var showEvaluation = false
    @State private var showQuitConfirmation = false
    @State private var showSourceWebView = false

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                // MARK: - Header Section
                HStack(spacing: Theme.Spacing.sm) {
                    // Progress badge
                    if let session = viewModel.currentSession {
                        ProgressBadge(
                            current: viewModel.questionsAnswered,
                            total: session.maxQuestions
                        )
                    }

                    Spacer()

                    // Score card
                    ScoreCard(
                        score: viewModel.score,
                        totalQuestions: viewModel.currentSession?.maxQuestions ?? 10
                    )
                    .frame(width: 100)

                    // Minimize button
                    Button {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            viewModel.isMinimized = true
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: Theme.Components.iconSM))
                            .foregroundColor(Theme.Colors.textSecondary)
                            .padding(Theme.Spacing.xs)
                            .background(Theme.Colors.bgCard)
                            .cornerRadius(Theme.Radius.sm)
                    }
                }
                .padding(.horizontal)

                // MARK: - Result Badge
                if let evaluation = viewModel.resultEvaluation {
                    VStack(spacing: Theme.Spacing.lg) {
                        if showEvaluation {
                            ResultBadge(
                                type: resultBadgeType(for: evaluation.result),
                                points: evaluation.points
                            )
                            .transition(.scale.combined(with: .opacity))
                        } else {
                            Text("Let's see...")
                                .font(.system(size: Theme.Typography.sizeLG, weight: .bold))
                                .foregroundColor(Theme.Colors.textSecondary)
                                .padding(.vertical, Theme.Spacing.xl)
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

                // MARK: - Auto-advance indicator
                if viewModel.autoAdvanceEnabled && !viewModel.currentQuestionPaused {
                    if viewModel.autoAdvanceCountdown > 0 {
                        CountdownTimer(seconds: viewModel.autoAdvanceCountdown)
                    } else {
                        HStack(spacing: Theme.Spacing.xs) {
                            ProgressView()
                                .scaleEffect(0.8)
                                .tint(Theme.Colors.accentPrimary)
                            Text("Loading next question...")
                                .font(.system(size: Theme.Typography.sizeXS))
                                .foregroundColor(Theme.Colors.textSecondary)
                        }
                    }
                } else if viewModel.currentQuestionPaused {
                    Text("Staying on this question")
                        .font(.system(size: Theme.Typography.sizeXS))
                        .foregroundColor(Theme.Colors.textSecondary)
                }

                // MARK: - Action Buttons
                VStack(spacing: Theme.Spacing.sm) {
                    PrimaryButton(title: "Continue", icon: "arrow.right") {
                        viewModel.continueToNext()
                    }

                    Button(action: {
                        viewModel.pauseQuiz()
                    }) {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "hand.raised.fill")
                            Text("Stay Here")
                        }
                    }
                    .buttonStyle(.secondary)
                    .disabled(viewModel.currentQuestionPaused)

                    // View Source button
                    if viewModel.resultQuestion?.sourceUrl != nil {
                        Button {
                            showSourceWebView = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "link")
                                    .font(.system(size: Theme.Typography.sizeXS))
                                Text("View Source")
                            }
                            .foregroundColor(Theme.Colors.accentPrimary)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, Theme.Spacing.lg)
            }
        }
        .background(Theme.Colors.bgPrimary)
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: showEvaluation)
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
                .font(.system(size: Theme.Typography.sizeXS, weight: .semibold))
                .foregroundColor(Theme.Colors.textSecondary)
                .textCase(.uppercase)

            Text(answer)
                .font(.system(size: Theme.Typography.sizeMD))
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
                    .font(.system(size: Theme.Typography.sizeMD, weight: .semibold))
                    .foregroundColor(Theme.Colors.textPrimary)
            }

            Text(excerpt)
                .font(.system(size: Theme.Typography.sizeSM))
                .foregroundColor(Theme.Colors.textSecondary)
                .padding(Theme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Colors.accentPrimarySoft)
                .cornerRadius(Theme.Radius.sm)

            Button(action: onReadMore) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text("Read Full Article")
                    Image(systemName: "arrow.up.forward.circle")
                }
                .font(.system(size: Theme.Typography.sizeSM))
                .foregroundColor(Theme.Colors.accentPrimary)
            }
        }
        .padding(Theme.Spacing.md)
        .background(Theme.Colors.bgCard)
        .cornerRadius(Theme.Radius.md)
    }
}

#Preview {
    ResultView(viewModel: QuizViewModel.previewWithEvaluation)
}
