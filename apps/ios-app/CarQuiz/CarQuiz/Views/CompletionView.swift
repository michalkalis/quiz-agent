//
//  CompletionView.swift
//  CarQuiz
//
//  Quiz completion and session summary matching Pencil design
//

import SwiftUI

struct CompletionView: View {
    @ObservedObject var viewModel: QuizViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                // Close button
                HStack {
                    Spacer()
                    Button {
                        viewModel.resetToHome()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: Theme.Components.iconSM, weight: .medium))
                            .foregroundColor(Theme.Colors.textSecondary)
                            .padding(Theme.Spacing.sm)
                            .background(Theme.Colors.bgCard)
                            .cornerRadius(Theme.Radius.full)
                    }
                }
                .padding(.horizontal)

                // MARK: - Trophy Section
                VStack(spacing: Theme.Spacing.md) {
                    Text("Quiz Master!")
                        .font(.system(size: Theme.Typography.sizeXXL, weight: .bold))
                        .foregroundColor(Theme.Colors.textPrimary)

                    Text(congratulatoryMessage)
                        .font(.system(size: Theme.Typography.sizeMD))
                        .foregroundColor(Theme.Colors.textSecondary)
                }

                // Trophy Icon
                TrophyIcon(size: 120)
                    .padding(.vertical, Theme.Spacing.lg)

                // MARK: - Score Card
                VStack(spacing: Theme.Spacing.sm) {
                    Text("Final Score")
                        .font(.system(size: Theme.Typography.sizeXS, weight: .medium))
                        .foregroundColor(Theme.Colors.textSecondary)

                    Text(formattedScore)
                        .font(.system(size: 56, weight: .heavy))
                        .foregroundColor(Theme.Colors.accentPrimary)

                    Text("\(Int(scorePercentage))% Accuracy")
                        .font(.system(size: Theme.Typography.sizeMD, weight: .medium))
                        .foregroundColor(Theme.Colors.textSecondary)
                }
                .padding(Theme.Spacing.xl)
                .frame(maxWidth: .infinity)
                .background(Theme.Colors.bgCard)
                .cornerRadius(Theme.Radius.xl)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.xl)
                        .stroke(Theme.Gradients.cardBorder(), lineWidth: 2)
                )
                .padding(.horizontal)

                // MARK: - Stats Row
                HStack(spacing: Theme.Spacing.md) {
                    StatsCard(
                        icon: "checkmark.circle.fill",
                        value: "\(viewModel.questionsAnswered)",
                        label: "Correct",
                        iconColor: Theme.Colors.success
                    )

                    StatsCard(
                        icon: "flame.fill",
                        value: "\(viewModel.currentStreak)",
                        label: "Streak",
                        iconColor: Theme.Colors.warning
                    )
                }
                .padding(.horizontal)

                Spacer(minLength: Theme.Spacing.xl)

                // MARK: - Action Buttons
                VStack(spacing: Theme.Spacing.sm) {
                    PrimaryButton(
                        title: "Play Again",
                        icon: "arrow.clockwise",
                        isLoading: viewModel.isLoading
                    ) {
                        Task {
                            await viewModel.startNewQuiz()
                        }
                    }

                    SecondaryButton(title: "Back to Home") {
                        viewModel.resetToHome()
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, Theme.Spacing.lg)
            }
        }
        .background(Theme.Colors.bgPrimary)
    }

    // MARK: - Computed Properties

    private var maxQuestions: Int {
        viewModel.currentSession?.maxQuestions ?? viewModel.questionsAnswered
    }

    private var scorePercentage: Double {
        guard maxQuestions > 0 else { return 0 }
        return (viewModel.score / Double(maxQuestions)) * 100
    }

    private var formattedScore: String {
        if viewModel.score.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(viewModel.score)) / \(maxQuestions)"
        } else {
            return String(format: "%.1f / %d", viewModel.score, maxQuestions)
        }
    }

    private var congratulatoryMessage: String {
        if scorePercentage >= 90 {
            return "Outstanding performance!"
        } else if scorePercentage >= 80 {
            return "Great job!"
        } else if scorePercentage >= 60 {
            return "Well done!"
        } else {
            return "Good effort!"
        }
    }
}

#Preview {
    let viewModel = QuizViewModel.previewWithEvaluation
    viewModel.score = 8.5
    viewModel.questionsAnswered = 10
    viewModel.quizState = .finished

    return CompletionView(viewModel: viewModel)
}
