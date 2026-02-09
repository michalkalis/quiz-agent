//
//  QuestionView.swift
//  CarQuiz
//
//  Main quiz screen with question display and voice recording
//

import SwiftUI

struct QuestionView: View {
    @ObservedObject var viewModel: QuizViewModel

    @State private var showEndQuizConfirmation = false

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            // Drag indicator pill
            Capsule()
                .fill(Theme.Colors.textSecondary.opacity(0.4))
                .frame(width: 36, height: 5)
                .padding(.top, Theme.Spacing.sm)

            // Close button (top-right)
            HStack {
                Spacer()
                Button {
                    showEndQuizConfirmation = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: Theme.Typography.sizeMD, weight: .semibold))
                        .foregroundColor(Theme.Colors.textSecondary)
                        .padding(Theme.Spacing.sm)
                        .background(Theme.Colors.bgCard)
                        .clipShape(Circle())
                }
                .disabled(!canInteract)
            }
            .padding(.horizontal)

            // Question content
            if let question = viewModel.currentQuestion {
                VStack(spacing: Theme.Spacing.md) {
                    // Inline badges: progress + category
                    HStack(spacing: Theme.Spacing.sm) {
                        if let session = viewModel.currentSession,
                           viewModel.questionsAnswered < session.maxQuestions {
                            ProgressBadge(
                                current: viewModel.questionsAnswered + 1,
                                total: session.maxQuestions
                            )
                        }
                        CategoryBadge(category: question.topic)
                    }

                    // Question text in card
                    Text(question.question)
                        .font(.system(size: Theme.Typography.sizeXL, weight: .bold))
                        .foregroundColor(Theme.Colors.textPrimary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(Theme.Spacing.lg)
                        .frame(maxWidth: .infinity)
                        .background(Theme.Colors.bgCard)
                        .cornerRadius(Theme.Radius.xl)
                        .padding(.horizontal, Theme.Spacing.md)
                }
            } else {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(Theme.Colors.accentPrimary)
            }

            Spacer()

            // Answer timer badge
            if viewModel.answerTimerCountdown > 0 && viewModel.quizState == .askingQuestion {
                AnswerTimerBadge(seconds: viewModel.answerTimerCountdown)
            }

            // Recording status hint
            Text(hintText)
                .font(.system(size: Theme.Typography.sizeSM, weight: .medium))
                .foregroundColor(hintColor)
                .frame(height: 24)
                .padding(.bottom, Theme.Spacing.sm)

            // Microphone button
            MicButton(state: micButtonState, action: handleMicrophoneTap)

            // Skip button (smaller, text only)
            Button {
                Task { await viewModel.skipQuestion() }
            } label: {
                Text("Skip")
                    .font(.system(size: Theme.Typography.sizeSM, weight: .medium))
            }
            .buttonStyle(.secondary)
            .disabled(!canInteract)

            // Error message
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.system(size: Theme.Typography.sizeXS))
                    .foregroundColor(Theme.Colors.error)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .padding(.top, Theme.Spacing.xs)
            }

            Spacer(minLength: Theme.Spacing.xs)
        }
        .padding()
        .background(Theme.Colors.bgPrimary)
        .interactiveMinimize(
            isMinimized: $viewModel.isMinimized,
            canMinimize: viewModel.canMinimize
        )
        .sheet(isPresented: $viewModel.showAnswerConfirmation, onDismiss: {
            viewModel.handleAnswerConfirmationDismissed()
        }) {
            AnswerConfirmationView(
                // Fixed: processing = in .processing state AND no transcription yet
                isProcessing: viewModel.quizState == .processing && viewModel.transcribedAnswer.isEmpty,
                transcribedAnswer: viewModel.transcribedAnswer,
                onConfirm: {
                    Task {
                        await viewModel.confirmAnswer()
                    }
                },
                onReRecord: {
                    viewModel.rerecordAnswer()
                },
                onCancel: {
                    viewModel.cancelProcessing()
                }
            )
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

    // MARK: - Hint Text

    private var hintText: String {
        switch viewModel.quizState {
        case .recording:
            return "Recording..."
        case .processing:
            return "Processing your answer..."
        case .askingQuestion where viewModel.answerTimerCountdown > 0:
            return "Recording starts automatically..."
        default:
            return "Tap to answer"
        }
    }

    private var hintColor: Color {
        switch viewModel.quizState {
        case .recording:
            return Theme.Colors.recording
        case .processing:
            return Theme.Colors.accentPrimary
        default:
            return Theme.Colors.textSecondary
        }
    }

    // MARK: - Computed Properties

    /// Whether Skip/End Quiz buttons are interactive (disabled during recording/processing)
    private var canInteract: Bool {
        viewModel.quizState == .askingQuestion
    }

    private var micButtonState: MicButton.State {
        switch viewModel.quizState {
        case .recording:
            return .recording
        case .processing:
            return .processing
        default:
            return .idle
        }
    }

    // MARK: - Actions

    private func handleMicrophoneTap() {
        Task { await viewModel.toggleRecording() }
    }
}

// MARK: - Answer Timer Badge

private struct AnswerTimerBadge: View {
    let seconds: Int

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "hourglass")
                .font(.system(size: Theme.Typography.sizeSM))
            Text("\(seconds)s")
                .font(.system(size: Theme.Typography.sizeMD, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundColor(seconds <= 5 ? Theme.Colors.error : Theme.Colors.accentPrimary)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
        .background(
            (seconds <= 5 ? Theme.Colors.errorBg : Theme.Colors.accentPrimary.opacity(0.15))
        )
        .cornerRadius(Theme.Radius.lg)
    }
}

// MARK: - Pulsing Animation

struct PulsingAnimation: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPulsing ? 1.2 : 1.0)
            .opacity(isPulsing ? 0.6 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear {
                isPulsing = true
            }
    }
}

#Preview {
    QuestionView(viewModel: QuizViewModel.preview)
}
