//
//  QuestionView.swift
//  CarQuiz
//
//  Main quiz screen with question display and voice recording
//

import SwiftUI

struct QuestionView: View {
    @ObservedObject var viewModel: QuizViewModel
    @EnvironmentObject var appState: AppState

    @State private var recordingError: String?
    @State private var audioData: Data?
    @State private var showEndQuizConfirmation = false

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            // Header: Progress, Score, and Minimize
            HStack {
                // Progress badge
                if let session = viewModel.currentSession,
                   viewModel.questionsAnswered < session.maxQuestions {
                    ProgressBadge(
                        current: viewModel.questionsAnswered + 1,
                        total: session.maxQuestions
                    )
                }

                Spacer()

                // Score card (compact)
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
                .disabled(!viewModel.canMinimize)
            }
            .padding(.horizontal)

            Spacer()

            // Question content
            if let question = viewModel.currentQuestion {
                VStack(spacing: Theme.Spacing.md) {
                    // Topic badge
                    CategoryBadge(category: question.topic)

                    // Question text in card
                    Text(question.question)
                        .font(.system(size: Theme.Typography.sizeXL, weight: .bold))
                        .foregroundColor(Theme.Colors.textPrimary)
                        .multilineTextAlignment(.center)
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

            // Recording status hint
            Text(hintText)
                .font(.system(size: Theme.Typography.sizeSM, weight: .medium))
                .foregroundColor(hintColor)
                .frame(height: 24)
                .padding(.bottom, Theme.Spacing.md)

            // Microphone button
            MicButton(state: micButtonState, action: handleMicrophoneTap)

            // Skip & End Quiz buttons
            HStack(spacing: Theme.Spacing.md) {
                Button {
                    Task { await viewModel.skipQuestion() }
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "forward.fill")
                        Text("Skip")
                    }
                }
                .buttonStyle(.secondary)
                .disabled(!canInteract)

                Button {
                    showEndQuizConfirmation = true
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "xmark.circle.fill")
                        Text("End Quiz")
                    }
                }
                .buttonStyle(.danger)
                .disabled(!canInteract)
            }
            .padding(.horizontal)

            // Error message
            if let error = recordingError ?? viewModel.errorMessage {
                Text(error)
                    .font(.system(size: Theme.Typography.sizeXS))
                    .foregroundColor(Theme.Colors.error)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .padding(.top, Theme.Spacing.sm)
            }

            Spacer(minLength: Theme.Spacing.lg)
        }
        .padding()
        .background(Theme.Colors.bgPrimary)
        .sheet(isPresented: $viewModel.showAnswerConfirmation) {
            AnswerConfirmationView(
                isProcessing: viewModel.quizState == .processing,
                transcribedAnswer: viewModel.transcribedAnswer,
                onConfirm: {
                    Task {
                        await viewModel.confirmAnswer()
                    }
                },
                onReRecord: {
                    viewModel.rerecordAnswer()
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
        recordingError = nil
        viewModel.errorMessage = nil

        Task {
            do {
                switch viewModel.quizState {
                case .askingQuestion:
                    // OPTIMISTIC UI: Lock button immediately to prevent double-tap
                    viewModel.quizState = .recording
                    do {
                        await appState.audioService.prepareForRecording()
                        try appState.audioService.startRecording()
                    } catch {
                        // Rollback on failure
                        viewModel.quizState = .askingQuestion
                        throw error
                    }

                case .recording:
                    let data = try await appState.audioService.stopRecording()
                    await viewModel.submitVoiceAnswer(audioData: data)

                default:
                    break
                }
            } catch {
                recordingError = "Recording failed: \(error.localizedDescription)"
                viewModel.quizState = .askingQuestion

                if Config.verboseLogging {
                    print("❌ Recording error: \(error)")
                }
            }
        }
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
        .environmentObject(AppState())
}
