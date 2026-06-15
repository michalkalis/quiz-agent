//
//  MinimizedQuizView.swift
//  Hangs
//
//  Compact floating widget matching Pencil design (Hangs redesign, #54 task 54.6)
//

import SwiftUI

struct MinimizedQuizView: View {
    @ObservedObject var viewModel: QuizViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showEndQuizConfirmation = false

    var body: some View {
        VStack(spacing: Theme.Hangs.Spacing.xs) {
            // Progress + score
            VStack(spacing: Theme.Hangs.Spacing.xxs) {
                Text(String(format: "%02d / %02d", viewModel.questionsAnswered + 1, viewModel.currentSession?.maxQuestions ?? 10))
                    .font(.hangsMonoLabel)
                    .tracking(2)
                    .foregroundColor(Theme.Hangs.Colors.muted)

                Text(String(format: "%.1f", viewModel.score))
                    .font(.hangsDisplay(28))
                    .foregroundColor(Theme.Hangs.Colors.ink)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(String(localized: "Quiz in progress. Question \(viewModel.questionsAnswered + 1) of \(viewModel.currentSession?.maxQuestions ?? 10). Score: \(String(format: "%.1f", viewModel.score))", comment: "Accessibility label for the minimized quiz widget: progress and score"))
            .accessibilityHint(String(localized: "Tap to expand quiz", comment: "Accessibility hint for the minimized quiz widget"))

            stateRow

            Rectangle()
                .fill(Theme.Hangs.Colors.hairline)
                .frame(height: 1)

            // End-quiz: obvious, comfortably tappable (54.6 — replaces the
            // 22×22 offset ✕ chip the founder couldn't hit while driving).
            Button {
                showEndQuizConfirmation = true
            } label: {
                Text("End Quiz")
                    .font(.hangsBody(13, weight: .semibold))
                    .foregroundColor(Theme.Hangs.Colors.error)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "End quiz", comment: "Accessibility label for the end-quiz button in the minimized widget"))
        }
        .padding(.horizontal, Theme.Hangs.Spacing.md)
        .padding(.top, Theme.Hangs.Spacing.md)
        .padding(.bottom, Theme.Hangs.Spacing.xxs)
        .frame(width: Theme.Components.widgetWidth)
        .background(
            RoundedRectangle(cornerRadius: Theme.Hangs.Radius.card, style: .continuous)
                .fill(Theme.Hangs.Colors.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Hangs.Radius.card, style: .continuous)
                .stroke(Theme.Hangs.Colors.hairline, lineWidth: 1)
        )
        .hangsShadow(Theme.Hangs.Shadow.card)
        .onTapGesture {
            expand()
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

    // MARK: - State row

    @ViewBuilder
    private var stateRow: some View {
        if viewModel.quizState == .askingQuestion {
            Button {
                expand()
            } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: Theme.Components.iconSM))
                    .foregroundColor(Theme.Hangs.Colors.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: Theme.Components.widgetMicHeight)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Hangs.Radius.ctaSmall, style: .continuous)
                            .fill(Theme.Hangs.Colors.pink)
                    )
            }
            .hangsShadow(Theme.Hangs.Shadow.cta)
        } else if viewModel.quizState == .recording {
            statusLabel(text: "Recording...") {
                Image(systemName: "waveform")
                    .font(.hangsBody(12))
                    .foregroundColor(Theme.Hangs.Colors.pink)
                    .symbolEffect(.pulse, isActive: !reduceMotion)
            }
        } else if viewModel.quizState == .processing {
            statusLabel(text: "Processing...") {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(Theme.Hangs.Colors.pink)
            }
        } else if viewModel.quizState == .skipping {
            statusLabel(text: "Skipping...") {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(Theme.Hangs.Colors.muted)
            }
        } else if viewModel.quizState.isShowingResult {
            statusLabel(text: "Review") {
                Image(systemName: "checkmark.circle.fill")
                    .font(.hangsBody(12))
                    .foregroundColor(Theme.Hangs.Colors.greenCheck)
            }
        }
    }

    private func statusLabel(text: String, @ViewBuilder icon: () -> some View) -> some View {
        HStack(spacing: Theme.Hangs.Spacing.xs) {
            icon()
            Text(text)
                .font(.hangsBody(12, weight: .medium))
                .foregroundColor(Theme.Hangs.Colors.muted)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Theme.Components.widgetMicHeight)
    }

    private func expand() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8)) {
            viewModel.isMinimized = false
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
    .background(Theme.Hangs.Colors.bg)
}
#endif
