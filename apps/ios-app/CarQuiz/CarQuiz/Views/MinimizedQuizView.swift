//
//  MinimizedQuizView.swift
//  CarQuiz
//
//  Compact floating widget matching Pencil design
//

import SwiftUI

struct MinimizedQuizView: View {
    @ObservedObject var viewModel: QuizViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showEndQuizConfirmation = false

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            // Progress text
            Text("\(viewModel.questionsAnswered + 1)/\(viewModel.currentSession?.maxQuestions ?? 10)")
                .font(.labelSM)
                .foregroundColor(Theme.Colors.textSecondary)

            // Score
            Text(String(format: "%.1f", viewModel.score))
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(Theme.Colors.accentPrimary)

            // State-specific mic button
            if viewModel.quizState == .askingQuestion {
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8)) {
                        viewModel.isMinimized = false
                    }
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: Theme.Components.iconSM))
                        .foregroundColor(Theme.Colors.textOnAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: Theme.Components.widgetMicHeight)
                        .background(Theme.Colors.accentPrimary)
                        .cornerRadius(Theme.Radius.xl)
                }
            } else if viewModel.quizState == .recording {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "waveform")
                        .font(.textXS)
                        .foregroundColor(Theme.Colors.recording)
                        .symbolEffect(.pulse, isActive: !reduceMotion)
                    Text("Recording...")
                        .font(.textXS)
                        .foregroundColor(Theme.Colors.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: Theme.Components.widgetMicHeight)
            } else if viewModel.quizState == .processing {
                HStack(spacing: Theme.Spacing.xs) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(Theme.Colors.accentPrimary)
                    Text("Processing...")
                        .font(.textXS)
                        .foregroundColor(Theme.Colors.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: Theme.Components.widgetMicHeight)
            } else if viewModel.quizState.isShowingResult {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.textXS)
                        .foregroundColor(Theme.Colors.success)
                    Text("Review")
                        .font(.textXS)
                        .foregroundColor(Theme.Colors.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: Theme.Components.widgetMicHeight)
            }
        }
        .padding(Theme.Spacing.md)
        .frame(width: Theme.Components.widgetWidth)
        .background(Theme.Colors.bgCard)
        .cornerRadius(Theme.Radius.lg)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .stroke(Theme.Colors.border, lineWidth: 2)
        )
        .overlay(alignment: .topTrailing) {
            Button {
                showEndQuizConfirmation = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Theme.Colors.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(Theme.Colors.bgSecondary)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(Theme.Colors.border, lineWidth: 1)
                    )
            }
            .offset(x: 6, y: -6)
        }
        .shadow(
            color: Color.black.opacity(0.125),
            radius: 16,
            x: 0,
            y: 4
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Quiz in progress. Question \(viewModel.questionsAnswered + 1) of \(viewModel.currentSession?.maxQuestions ?? 10). Score: \(String(format: "%.1f", viewModel.score))")
        .accessibilityHint("Tap to expand quiz")
        .onTapGesture {
            withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8)) {
                viewModel.isMinimized = false
            }
        }
        .confirmationDialog(
            "End Quiz?",
            isPresented: $showEndQuizConfirmation,
            titleVisibility: .visible
        ) {
            Button("End Quiz", role: .destructive) {
                Task {
                    await viewModel.endQuiz()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to end the quiz? Your progress will be saved.")
        }
    }
}

#if DEBUG
#Preview {
    VStack {
        Spacer()
        MinimizedQuizView(viewModel: QuizViewModel.preview)
            .padding()
    }
    .background(Theme.Colors.bgSecondary)
}
#endif
