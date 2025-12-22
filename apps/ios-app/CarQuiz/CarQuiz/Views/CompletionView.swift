//
//  CompletionView.swift
//  CarQuiz
//
//  Quiz completion and session summary
//

import SwiftUI

struct CompletionView: View {
    @ObservedObject var viewModel: QuizViewModel

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Trophy icon
            Image(systemName: trophyIcon)
                .font(.system(size: 80))
                .foregroundColor(trophyColor)
                .transition(.scale.combined(with: .opacity))

            // Completion message
            VStack(spacing: 8) {
                Text("Quiz Complete!")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text(congratulatoryMessage)
                    .font(.title3)
                    .foregroundColor(.secondary)
            }

            // Score card
            VStack(spacing: 24) {
                // Final score circle
                ZStack {
                    Circle()
                        .stroke(Color.gray.opacity(0.2), lineWidth: 12)
                        .frame(width: 160, height: 160)

                    Circle()
                        .trim(from: 0, to: scorePercentage / 100)
                        .stroke(
                            scoreColor,
                            style: StrokeStyle(lineWidth: 12, lineCap: .round)
                        )
                        .frame(width: 160, height: 160)
                        .rotationEffect(.degrees(-90))
                        .animation(.spring(response: 1.0, dampingFraction: 0.7), value: viewModel.score)

                    VStack(spacing: 4) {
                        Text("\(formattedScore)")
                            .font(.system(size: 48, weight: .bold))

                        Text("out of \(maxQuestions)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // Stats
                HStack(spacing: 40) {
                    StatView(
                        icon: "checkmark.circle.fill",
                        value: "\(viewModel.questionsAnswered)",
                        label: "Questions"
                    )

                    StatView(
                        icon: "percent",
                        value: "\(Int(scorePercentage))%",
                        label: "Accuracy"
                    )
                }
            }
            .padding(.vertical)

            Spacer()

            // Actions
            VStack(spacing: 16) {
                // Start another quiz
                Button(action: {
                    Task {
                        await viewModel.startNewQuiz()
                    }
                }) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                            .font(.title2)

                        Text("Start Another Quiz")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(viewModel.isLoading ? Color.blue.opacity(0.5) : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(16)
                }
                .disabled(viewModel.isLoading)

                // Go home
                Button(action: {
                    viewModel.resetToHome()
                }) {
                    Text("Done")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .foregroundColor(.primary)
                        .cornerRadius(16)
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
        }
        .padding()
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
            return "\(Int(viewModel.score))"
        } else {
            return String(format: "%.1f", viewModel.score)
        }
    }

    private var trophyIcon: String {
        if scorePercentage >= 80 {
            return "trophy.fill"
        } else if scorePercentage >= 60 {
            return "star.fill"
        } else {
            return "flag.checkered"
        }
    }

    private var trophyColor: Color {
        if scorePercentage >= 80 {
            return .yellow
        } else if scorePercentage >= 60 {
            return .orange
        } else {
            return .blue
        }
    }

    private var scoreColor: Color {
        if scorePercentage >= 80 {
            return .green
        } else if scorePercentage >= 60 {
            return .orange
        } else {
            return .red
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

// MARK: - Stat View Component

struct StatView: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.blue)

            Text(value)
                .font(.title3)
                .fontWeight(.semibold)

            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
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
