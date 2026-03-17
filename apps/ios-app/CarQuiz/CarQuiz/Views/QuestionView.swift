//
//  QuestionView.swift
//  CarQuiz
//
//  Main quiz screen with question display and voice recording
//

import SwiftUI

struct QuestionView: View {
    @ObservedObject var viewModel: QuizViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showEndQuizConfirmation = false
    @State private var showTextInput = false
    @State private var textAnswer = ""
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            // Drag indicator pill
            Capsule()
                .fill(Theme.Colors.textSecondary.opacity(0.4))
                .frame(width: 36, height: 5)
                .padding(.top, Theme.Spacing.sm)
                .accessibilityHidden(true)

            // Top bar: voice indicator + close button
            HStack {
                // Voice command indicator (left)
                if viewModel.voiceCommandsAvailable {
                    VoiceCommandIndicator(state: viewModel.voiceCommandState)
                }

                Spacer()

                Button {
                    showEndQuizConfirmation = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.displayMD)
                        .foregroundColor(Theme.Colors.textSecondary)
                        .padding(Theme.Spacing.sm)
                        .background(Theme.Colors.bgCard)
                        .clipShape(Circle())
                }
                .accessibilityLabel("End quiz")
                .accessibilityIdentifier("question.endQuiz")
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

                    // Image or text question card
                    if question.hasImage {
                        ImageQuestionView(question: question)
                    } else {
                        Text(question.question)
                            .font(.displayXL)
                            .foregroundColor(Theme.Colors.textPrimary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(Theme.Spacing.lg)
                            .frame(maxWidth: .infinity)
                            .background(Theme.Colors.bgCard)
                            .cornerRadius(Theme.Radius.xl)
                            .padding(.horizontal, Theme.Spacing.md)
                            .accessibilityIdentifier("question.text")
                    }
                }
            } else {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(Theme.Colors.accentPrimary)
            }

            Spacer()

            // Branch: MCQ options vs voice recording
            if let question = viewModel.currentQuestion, question.isMultipleChoice {
                // MCQ path: show option picker + skip only
                MCQOptionPicker(
                    options: question.sortedAnswerOptions,
                    onSelect: { key, value in
                        Task { await viewModel.submitMCQAnswer(key: key, value: value) }
                    }
                )

                Button {
                    Task { await viewModel.skipQuestion() }
                } label: {
                    Text("Skip")
                        .font(.textMDMedium)
                }
                .accessibilityLabel("Skip question")
                .accessibilityHint("Skip this question and move to the next one")
                .accessibilityIdentifier("question.skip")
                .buttonStyle(.secondary)
                .disabled(!canInteract)
            } else {
                // Non-MCQ path: voice recording UI

                // Answer timer badge
                if viewModel.answerTimerCountdown > 0 && viewModel.quizState == .askingQuestion {
                    AnswerTimerBadge(seconds: viewModel.answerTimerCountdown)
                }

                // Live transcript from streaming STT
                if viewModel.isStreamingSTT && !viewModel.liveTranscript.isEmpty {
                    Text(viewModel.liveTranscript)
                        .font(.textMDBodyMedium)
                        .foregroundColor(Theme.Colors.textPrimary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, Theme.Spacing.sm)
                        .frame(maxWidth: .infinity)
                        .background(Theme.Colors.bgCard.opacity(0.8))
                        .cornerRadius(Theme.Radius.lg)
                        .padding(.horizontal, Theme.Spacing.md)
                        .transition(.opacity)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: viewModel.liveTranscript)
                        .accessibilityLabel("Transcription: \(viewModel.liveTranscript)")
                }

                // Recording status hint
                Text(hintText)
                    .font(.textMDMedium)
                    .foregroundColor(hintColor)
                    .frame(height: 24)
                    .padding(.bottom, Theme.Spacing.sm)
                    .accessibilityLabel("Status: \(hintText)")

                // Microphone button
                MicButton(state: micButtonState, action: handleMicrophoneTap)
                    .accessibilityIdentifier("question.micButton")

                // Skip + Type answer buttons
                HStack(spacing: Theme.Spacing.sm) {
                    Button {
                        Task { await viewModel.skipQuestion() }
                    } label: {
                        Text("Skip")
                            .font(.textMDMedium)
                    }
                    .accessibilityLabel("Skip question")
                    .accessibilityHint("Skip this question and move to the next one")
                    .accessibilityIdentifier("question.skip")
                    .buttonStyle(.secondary)
                    .disabled(!canInteract)

                    Button {
                        showTextInput.toggle()
                        if showTextInput { isTextFieldFocused = true }
                    } label: {
                        Image(systemName: "keyboard")
                            .font(.system(size: Theme.Components.iconSM))
                    }
                    .accessibilityLabel("Type answer")
                    .accessibilityHint("Switch to typing your answer instead of speaking")
                    .accessibilityIdentifier("question.textInputToggle")
                    .buttonStyle(.secondary)
                    .disabled(!canInteract)
                }

                // Text input fallback
                if showTextInput {
                    HStack(spacing: Theme.Spacing.xs) {
                        TextField("Type your answer...", text: $textAnswer)
                            .font(.textMD)
                            .textFieldStyle(.roundedBorder)
                            .focused($isTextFieldFocused)
                            .accessibilityIdentifier("question.textField")
                            .submitLabel(.send)
                            .onSubmit {
                                guard !textAnswer.isEmpty else { return }
                                let answer = textAnswer
                                textAnswer = ""
                                showTextInput = false
                                Task { await viewModel.resubmitAnswer(answer) }
                            }

                        Button {
                            guard !textAnswer.isEmpty else { return }
                            let answer = textAnswer
                            textAnswer = ""
                            showTextInput = false
                            Task { await viewModel.resubmitAnswer(answer) }
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: Theme.Components.iconLG))
                                .foregroundColor(textAnswer.isEmpty ? Theme.Colors.textMuted : Theme.Colors.accentPrimary)
                        }
                        .accessibilityLabel("Submit typed answer")
                        .accessibilityIdentifier("question.textSubmit")
                        .disabled(textAnswer.isEmpty)
                    }
                    .padding(.horizontal, Theme.Spacing.md)
                }
            }

            // Error message
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.textXS)
                    .foregroundColor(Theme.Colors.error)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .padding(.top, Theme.Spacing.xs)
                    .accessibilityLabel("Error: \(error)")
                    .accessibilityIdentifier("question.error")
                    .accessibilityAddTraits(.isStaticText)
            }

            Spacer(minLength: Theme.Spacing.xs)
        }
        .padding()
        .background(Theme.Colors.bgPrimary)
        .sensoryFeedback(.start, trigger: viewModel.quizState == .recording)
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
        case .recording where viewModel.isStreamingSTT && !viewModel.liveTranscript.isEmpty:
            return "Transcribing..."
        case .recording where viewModel.isStreamingSTT:
            return "Listening..."
        case .recording where viewModel.isAutoRecording && viewModel.speechDetectedDuringAutoRecord:
            return "Speaking..."
        case .recording where viewModel.isAutoRecording:
            return "Listening..."
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
        case .recording where viewModel.isStreamingSTT && !viewModel.liveTranscript.isEmpty:
            return Theme.Colors.accentPrimary
        case .recording where viewModel.isStreamingSTT:
            return Theme.Colors.accentPrimary
        case .recording where viewModel.isAutoRecording && viewModel.speechDetectedDuringAutoRecord:
            return Theme.Colors.recording
        case .recording where viewModel.isAutoRecording:
            return Theme.Colors.accentPrimary
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
                .font(.textSM)
                .accessibilityHidden(true)
            Text("\(seconds)s")
                .font(.displayMD)
                .monospacedDigit()
        }
        .foregroundColor(seconds <= 5 ? Theme.Colors.error : Theme.Colors.accentPrimary)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
        .background(
            (seconds <= 5 ? Theme.Colors.errorBg : Theme.Colors.accentPrimary.opacity(0.15))
        )
        .cornerRadius(Theme.Radius.lg)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(seconds) seconds remaining")
    }
}

// MARK: - Pulsing Animation

struct PulsingAnimation: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPulsing && !reduceMotion ? 1.2 : 1.0)
            .opacity(isPulsing && !reduceMotion ? 0.6 : 1.0)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear {
                isPulsing = true
            }
    }
}

#Preview {
    QuestionView(viewModel: QuizViewModel.preview)
}
