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

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            // Header: Progress and Score
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
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "star.fill")
                        .font(.system(size: Theme.Typography.sizeXS))
                        .foregroundColor(Theme.Colors.warning)

                    Text("\(Int(viewModel.score))")
                        .font(.displayMD)
                        .foregroundColor(Theme.Colors.textPrimary)
                }
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, Theme.Spacing.xs)
                .background(Theme.Colors.bgElevated)
                .cornerRadius(Theme.Radius.sm)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .stroke(Theme.Colors.border, lineWidth: 1)
                )
            }
            .padding(.horizontal)

            Spacer()

            // Question content
            if let question = viewModel.currentQuestion {
                VStack(spacing: Theme.Spacing.md) {
                    // Topic badge
                    CategoryBadge(category: question.topic)

                    // Question text
                    Text(question.question)
                        .font(.displayLG)
                        .foregroundColor(Theme.Colors.textPrimary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Theme.Spacing.xl)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(Theme.Colors.accentPrimary)
            }

            Spacer()

            // Recording status
            VStack(spacing: Theme.Spacing.xs) {
                if viewModel.quizState == .recording {
                    HStack(spacing: Theme.Spacing.xs) {
                        Circle()
                            .fill(Theme.Colors.recording)
                            .frame(width: 12, height: 12)
                            .modifier(PulsingAnimation())

                        Text("Recording...")
                            .font(.displayMD)
                            .foregroundColor(Theme.Colors.recording)
                    }
                } else if viewModel.quizState == .processing {
                    HStack(spacing: Theme.Spacing.sm) {
                        ProgressView()
                            .tint(Theme.Colors.accentPrimary)
                        Text("Processing your answer...")
                            .font(.textSM)
                            .foregroundColor(Theme.Colors.textSecondary)
                    }
                } else {
                    Text("Tap to answer")
                        .font(.textSM)
                        .foregroundColor(Theme.Colors.textSecondary)
                }
            }
            .frame(height: 24)
            .padding(.bottom, Theme.Spacing.md)

            // Microphone button
            MicButton(state: micButtonState, action: handleMicrophoneTap)
                .padding(.bottom, Theme.Spacing.xxl)

            // Error message
            if let error = recordingError ?? viewModel.errorMessage {
                Text(error)
                    .font(.textXS)
                    .foregroundColor(Theme.Colors.error)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .padding(.bottom)
            }
        }
        .padding()
        .background(Theme.Colors.bgPrimary)
        .sheet(isPresented: $viewModel.showAnswerConfirmation) {
            AnswerConfirmationView(
                isProcessing: viewModel.isLoading,
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
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        viewModel.isMinimized = true
                    }
                }) {
                    Label("Minimize", systemImage: "arrow.down.right.and.arrow.up.left")
                        .foregroundColor(Theme.Colors.accentPrimary)
                }
                .disabled(!viewModel.canMinimize)
            }
        }
    }

    // MARK: - Computed Properties

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
