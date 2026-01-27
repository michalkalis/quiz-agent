//
//  MinimizedQuizView.swift
//  CarQuiz
//
//  Compact floating widget matching Pencil design
//

import SwiftUI

struct MinimizedQuizView: View {
    @ObservedObject var viewModel: QuizViewModel

    @State private var showEndQuizConfirmation = false

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            // Progress text
            Text("\(viewModel.questionsAnswered + 1)/\(viewModel.currentSession?.maxQuestions ?? 10)")
                .font(.system(size: Theme.Typography.sizeXS, weight: .semibold))
                .foregroundColor(Theme.Colors.textSecondary)

            // Score
            Text(String(format: "%.1f", viewModel.score))
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(Theme.Colors.accentPrimary)

            // State-specific mic button
            if viewModel.quizState == .askingQuestion {
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
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
                        .font(.system(size: Theme.Typography.sizeXS))
                        .foregroundColor(Theme.Colors.recording)
                        .symbolEffect(.pulse)
                    Text("Recording...")
                        .font(.system(size: Theme.Typography.sizeXS))
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
                        .font(.system(size: Theme.Typography.sizeXS))
                        .foregroundColor(Theme.Colors.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: Theme.Components.widgetMicHeight)
            } else if viewModel.quizState == .showingResult {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: Theme.Typography.sizeXS))
                        .foregroundColor(Theme.Colors.success)
                    Text("Review")
                        .font(.system(size: Theme.Typography.sizeXS))
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
        .onTapGesture {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
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

#Preview {
    VStack {
        Spacer()
        MinimizedQuizView(viewModel: QuizViewModel.preview)
            .padding()
    }
    .background(Theme.Colors.bgSecondary)
}
