//
//  ResultView.swift
//  CarQuiz
//
//  Answer evaluation and feedback display
//

import SwiftUI

struct ResultView: View {
    @ObservedObject var viewModel: QuizViewModel

    @State private var showEvaluation = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Result icon and status
            if let evaluation = viewModel.lastEvaluation {
                VStack(spacing: 24) {
                    // Show evaluation result after 2-second delay
                    if showEvaluation {
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
                    } else {
                        // Before showing result, show waiting message
                        Text("Let's see...")
                            .font(.title)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 40)
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

                    // Correct answer (shown after evaluation)
                    if showEvaluation {
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

            // Continue button
            Button(action: {
                viewModel.continueToNext()
            }) {
                HStack(spacing: 12) {
                    Text("Continue")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.title3)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Color.blue)
                .cornerRadius(16)
            }
            .padding(.horizontal, 32)

            // Cancel button (for auto-advance)
            HStack {
                Button(action: {
                    viewModel.pauseQuiz()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "xmark.circle")
                        Text("Cancel")
                    }
                    .font(.callout)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.currentQuestionPaused)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 20)

            // Auto-advance indicator
            if viewModel.autoAdvanceEnabled && !viewModel.currentQuestionPaused {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    if viewModel.autoAdvanceCountdown > 0 {
                        Text("Auto-advancing in \(viewModel.autoAdvanceCountdown) second\(viewModel.autoAdvanceCountdown == 1 ? "" : "s")...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Loading next question...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.bottom, 20)
            } else if viewModel.currentQuestionPaused {
                Text("Auto-advance paused for this question")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 20)
            }
        }
        .padding()
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: viewModel.lastEvaluation)
        .onAppear {
            // Show evaluation immediately - no timer
            showEvaluation = true
        }
        .toolbar {
            // Minimize button (top-left)
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        viewModel.isMinimized = true
                    }
                }) {
                    Label("Minimize", systemImage: "arrow.down.right.and.arrow.up.left")
                }
            }

            // End Quiz button (top-right)
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    Task {
                        await viewModel.endQuiz()
                    }
                }) {
                    Label("End Quiz", systemImage: "xmark.circle")
                }
                .tint(.red)
            }
        }
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
