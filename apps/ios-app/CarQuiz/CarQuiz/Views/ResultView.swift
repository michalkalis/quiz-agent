//
//  ResultView.swift
//  CarQuiz
//
//  Answer evaluation and feedback display
//

import SwiftUI

struct ResultView: View {
    @ObservedObject var viewModel: QuizViewModel

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Result icon and status
            if let evaluation = viewModel.lastEvaluation {
                VStack(spacing: 24) {
                    // Icon with animation
                    Image(systemName: resultIcon(for: evaluation.result))
                        .font(.system(size: 80))
                        .foregroundColor(resultColor(for: evaluation.result))
                        .transition(.scale.combined(with: .opacity))

                    // Result text
                    Text(resultText(for: evaluation.result))
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundColor(resultColor(for: evaluation.result))

                    // Points awarded
                    if evaluation.points > 0 {
                        HStack(spacing: 8) {
                            Image(systemName: "star.fill")
                                .foregroundColor(.yellow)
                            Text("+\(formatPoints(evaluation.points))")
                                .font(.title2)
                                .fontWeight(.semibold)
                        }
                    }
                }

                Divider()
                    .padding(.horizontal, 40)

                // Answer comparison
                VStack(spacing: 20) {
                    // User's answer
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your Answer:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)

                        Text(evaluation.userAnswer)
                            .font(.body)
                            .foregroundColor(.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(12)

                    // Correct answer (if wrong)
                    if evaluation.result != .correct {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Correct Answer:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .textCase(.uppercase)

                            Text(evaluation.correctAnswer)
                                .font(.body)
                                .foregroundColor(.primary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(12)
                    }
                }
                .padding(.horizontal, 32)
            } else {
                ProgressView()
                    .scaleEffect(1.5)
            }

            Spacer()

            // Auto-advance indicator
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Next question coming...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 40)
        }
        .padding()
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: viewModel.lastEvaluation)
    }

    // MARK: - Helper Functions

    private func resultIcon(for result: Evaluation.EvaluationResult) -> String {
        switch result {
        case .correct:
            return "checkmark.circle.fill"
        case .incorrect:
            return "xmark.circle.fill"
        case .partiallyCorrect, .partiallyIncorrect:
            return "exclamationmark.circle.fill"
        case .skipped:
            return "forward.circle.fill"
        }
    }

    private func resultColor(for result: Evaluation.EvaluationResult) -> Color {
        switch result {
        case .correct:
            return .green
        case .incorrect:
            return .red
        case .partiallyCorrect, .partiallyIncorrect:
            return .orange
        case .skipped:
            return .gray
        }
    }

    private func resultText(for result: Evaluation.EvaluationResult) -> String {
        switch result {
        case .correct:
            return "Correct!"
        case .incorrect:
            return "Incorrect"
        case .partiallyCorrect:
            return "Partially Correct"
        case .partiallyIncorrect:
            return "Partially Incorrect"
        case .skipped:
            return "Skipped"
        }
    }

    private func formatPoints(_ points: Double) -> String {
        if points.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(points))"
        } else {
            return String(format: "%.1f", points)
        }
    }
}

#Preview {
    ResultView(viewModel: QuizViewModel.previewWithEvaluation)
}
