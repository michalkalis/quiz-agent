//
//  MinimizedQuizView.swift
//  CarQuiz
//
//  Compact floating widget matching Pencil design
//

import SwiftUI

struct MinimizedQuizView: View {
    @ObservedObject var viewModel: QuizViewModel

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
