//
//  QuestionView.swift
//  Hangs
//
//  QuestionView redesigned to match Pencil frames b8zObz (MCQ), WCaT6 (TrueFalse),
//  f9csl (Listen/ready), uGhZg (Capture/recording) — issue #52 task 52.10.
//  MCQ: category+question-number header, AnswerOption list, ListeningPill, Skip.
//  Voice: lowercase category, display-font question, centered waveform state block,
//         Record/Stop | Skip action row.
//

import Combine
import SwiftUI

struct QuestionView: View {
    @ObservedObject var viewModel: QuizViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showEndQuizConfirmation = false
    @State private var showTextInput = false
    @State private var textAnswer = ""
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Theme.Hangs.Colors.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                topChrome

                if let question = viewModel.currentQuestion {
                    if question.isMultipleChoice {
                        mcqBody(question: question)
                    } else {
                        voiceBody(question: question)
                    }
                } else {
                    Spacer()
                    ProgressView().tint(Theme.Hangs.Colors.pink)
                    Spacer()
                }
            }
        }
        .sensoryFeedback(.start, trigger: viewModel.quizState == .recording)
        .interactiveMinimize(
            isMinimized: $viewModel.isMinimized,
            canMinimize: viewModel.canMinimize
        )
        .sheet(isPresented: $viewModel.showAnswerConfirmation, onDismiss: {
            viewModel.handleAnswerConfirmationDismissed()
        }) {
            AnswerConfirmationView(
                isProcessing: viewModel.quizState == .processing && viewModel.transcribedAnswer.isEmpty,
                transcribedAnswer: $viewModel.transcribedAnswer,
                autoConfirmCountdown: viewModel.autoConfirmCountdown,
                autoConfirmEnabled: viewModel.settings.autoConfirmEnabled,
                autoConfirmTotal: Config.autoConfirmDelaySecs,
                onConfirm: { Task { await viewModel.confirmAnswer() } },
                onReRecord: { viewModel.rerecordAnswer() },
                onEditingBegan: { viewModel.beginEditingTranscript() },
                onCancelEditing: { viewModel.cancelEditingTranscript() },
                onCancel: { viewModel.cancelProcessing() }
            )
        }
        .confirmationDialog(
            "End Quiz?",
            isPresented: $showEndQuizConfirmation,
            titleVisibility: .visible
        ) {
            Button("End Quiz", role: .destructive) {
                Task { await viewModel.endQuiz() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to end the quiz? Your progress will be saved.")
        }
    }

    // MARK: - Top chrome

    private var topChrome: some View {
        VStack(spacing: 8) {
            HangsQuizNav(
                onClose: { showEndQuizConfirmation = true },
                counterText: counterString,
                counterAccent: isRecording ? Theme.Hangs.Colors.pink : Theme.Hangs.Colors.muted
            )
            HangsProgressBar(progress: progressValue)
            if let error = viewModel.errorMessage {
                errorBanner(error)
            }
            supportRow
        }
    }

    private var counterString: String {
        let total = viewModel.currentSession?.maxQuestions ?? viewModel.settings.numberOfQuestions
        let current = min(viewModel.questionsAnswered + 1, max(total, 1))
        return String(format: "%02d / %02d", current, total)
    }

    private var progressValue: Double {
        let total = viewModel.currentSession?.maxQuestions ?? viewModel.settings.numberOfQuestions
        guard total > 0 else { return 0 }
        return min(1, Double(viewModel.questionsAnswered) / Double(total))
    }

    // MARK: - Error banner

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(error).font(.hangsBody(13))
        }
        .foregroundColor(Theme.Hangs.Colors.error)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.Hangs.Colors.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.Hangs.Colors.error.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, 24)
        .accessibilityLabel(String(localized: "Error: \(error)", comment: "Accessibility label for the in-quiz error banner"))
        .accessibilityIdentifier("question.errorBanner")
    }

    // MARK: - Support row (think/answer timers when active)

    /// Fixed height reserved for the timer-chip row throughout `askingQuestion`, so the
    /// chips fading in when the countdown starts never push the question + pinned controls
    /// downward (#59.2). ~timerChip height (text + 5pt vertical padding × 2 + capsule).
    private let supportRowHeight: CGFloat = 30

    @ViewBuilder
    private var supportRow: some View {
        // 59.2: reserve the slot for the *whole* askingQuestion phase rather than toggling
        // from EmptyView → real row the instant the countdown becomes non-zero. The chips
        // are conditionally rendered inside a constant-height frame so their appearance is a
        // pure fade-in with zero layout shift; the slot collapses once we leave askingQuestion.
        if viewModel.quizState == .askingQuestion {
            let showThink = viewModel.thinkingTimeCountdown > 0
            let showAnswer = viewModel.answerTimerCountdown > 0
            HStack(spacing: 8) {
                if showThink {
                    timerChip(label: "THINK", seconds: viewModel.thinkingTimeCountdown, color: Theme.Hangs.Colors.blue)
                }
                if showAnswer {
                    timerChip(label: "ANSWER", seconds: viewModel.answerTimerCountdown, color: Theme.Hangs.Colors.pink)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28)
            .frame(height: supportRowHeight, alignment: .leading)
        }
    }

    private func timerChip(label: LocalizedStringKey, seconds: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.hangsMono(10, weight: .semibold))
                .tracking(1.5)
            Text(verbatim: "\(seconds)s")
                .font(.hangsMono(12, weight: .semibold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.12)))
        .overlay(Capsule().stroke(color.opacity(0.4), lineWidth: 1))
    }

    // MARK: - Transcript card

    private var transcriptCard: some View {
        HangsCard(padding: EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)) {
            VStack(alignment: .leading, spacing: 10) {
                HangsSectionLabel(text: "TRANSCRIPT", color: Theme.Hangs.Colors.pink)
                LiveTranscriptView(
                    text: viewModel.liveTranscript,
                    isCommitted: !viewModel.isStreamingSTT
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 24)
        .accessibilityIdentifier("question.liveTranscript")
    }

    // MARK: - MCQ body (frames b8zObz / WCaT6)

    private func mcqBody(question: Question) -> some View {
        VStack(spacing: 0) {
            mcqQuestionHeader(question: question)

            ScrollView(.vertical, showsIndicators: false) {
                HangsQuestionPrompt(
                    text: question.question,
                    barColor: Theme.Hangs.Colors.blue,
                    textFont: .hangsQuestion
                )
                .accessibilityIdentifier("question.text")
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            MCQOptionPicker(
                options: question.sortedAnswerOptions,
                onSelect: { key, value in
                    Task { await viewModel.submitMCQAnswer(key: key, value: value) }
                },
                externalSelectedKey: viewModel.mcqVoiceMatchedKey
            )
            .padding(.top, 8)

            ListeningPill(mode: question.sortedAnswerOptions.count == 2 ? .trueFalse : .mcq)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 24)
                .padding(.top, 12)

            HangsSecondaryButton(title: "Skip question",
                                 icon: "play.forward.fill",
                                 height: 54)
            {
                Task { await viewModel.skipQuestion() }
            }
            .accessibilityIdentifier("question.skip")
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 28)

            #if DEBUG
                Text(quizStateName)
                    .frame(width: 0, height: 0)
                    .accessibilityIdentifier("question.state")
            #endif
        }
        .frame(maxHeight: .infinity)
    }

    // "CATEGORY · QUESTION N" header for MCQ (frames b8zObz, WCaT6)
    private func mcqQuestionHeader(question: Question) -> some View {
        // #56: text param is LocalizedStringKey; pass the interpolated literal
        // directly so the compiler extracts "%@ · QUESTION %lld" (category and
        // number are runtime placeholders).
        HangsSectionLabel(
            text: "\(question.category) · QUESTION \(currentQuestionNumber)",
            color: Theme.Hangs.Colors.pink
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    // MARK: - Voice body (frames f9csl / uGhZg)

    private func voiceBody(question: Question) -> some View {
        VStack(spacing: 0) {
            // Scroll region holds only category + question, so a long Slovak
            // question can scroll without pushing the pinned controls off-screen
            // (54.2). minHeight keeps short questions top-aligned, not centered.
            GeometryReader { geo in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        // Category: lowercase pink, no question number (design: f9csl)
                        Text(question.category.lowercased())
                            .font(.hangsMono(11, weight: .medium))
                            .tracking(2)
                            .foregroundColor(Theme.Hangs.Colors.pink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 24)
                            .padding(.top, 12)
                            .padding(.bottom, 4)
                            .accessibilityIdentifier("question.category")

                        // Question: Anton display, no left bar
                        Text(question.question)
                            .font(.hangsDisplay(28))
                            .foregroundColor(Theme.Hangs.Colors.ink)
                            .minimumScaleFactor(0.7)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 24)
                            .accessibilityIdentifier("question.text")

                        // Replay button — plays the question TTS again via a
                        // timer-free audio path (Decision 2): never restarts the
                        // auto-record/think countdown. Disabled when there's nothing to
                        // replay (muted or no question audio URL) so it doesn't look
                        // interactive while silently no-opping (#59.5).
                        Button {
                            Task { await viewModel.replayQuestionAudio() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("replay question")
                                    .font(.hangsBody(15, weight: .medium))
                            }
                            .foregroundColor(Theme.Hangs.Colors.blue)
                        }
                        .buttonStyle(.plain)
                        .disabled(!viewModel.canReplayAudio)
                        .opacity(viewModel.canReplayAudio ? 1 : 0.4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24)
                        .padding(.top, 14)
                        .accessibilityIdentifier("question.replay")
                    }
                    .frame(minHeight: geo.size.height, alignment: .top)
                }
            }

            // Pinned controls below the scroll region — transcript (recording
            // only), typed-answer fallback, then the Record/Skip action row.
            VStack(spacing: 12) {
                if isProcessing {
                    // 59.6: the typed-answer path (resubmitAnswer → .processing) stays on
                    // QuestionView — it does NOT open the voice AnswerConfirmationView sheet
                    // that owns the only other spinner. Without this branch the screen looked
                    // frozen between "send" and the result. Mirrors the sheet's processingBody.
                    processingRow
                } else {
                    // Live transcript (recording + STT streaming) — static, pinned
                    // directly above the buttons so it never scrolls away.
                    if isRecording && viewModel.isStreamingSTT {
                        transcriptCard
                    }

                    // Typed-answer fallback — onboarding promises a keyboard path
                    // for mic-denied users (#54 task 54.18).
                    if showTextInput {
                        textInputRow
                    } else {
                        textInputToggle
                    }

                    voiceActionRow
                        .padding(.horizontal, 24)
                }
            }
            .padding(.bottom, 28)

            #if DEBUG
                Text(quizStateName)
                    .frame(width: 0, height: 0)
                    .accessibilityIdentifier("question.state")
            #endif
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Voice action row (Record/Stop | Skip)

    private var voiceActionRow: some View {
        HStack(spacing: 12) {
            Button {
                // Manual override (54.3): toggleRecording starts recording
                // immediately from .askingQuestion (cancelling the auto-record
                // think/answer countdown) and stops+submits from .recording.
                // Auto-record still fires on its own via startRecordingOrTimer()
                // when the question is presented (QuizViewModel:440/945).
                Task { await viewModel.toggleRecording() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 17, weight: .semibold))
                    (isRecording ? Text("Stop", comment: "Record button label while recording is active") : Text("Record", comment: "Record button label to start recording an answer"))
                        .font(.hangsButton)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Capsule().fill(Theme.Hangs.Colors.pink))
                .hangsShadow(Theme.Hangs.Shadow.cta)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(isRecording ? "question.stop" : "question.record")

            Button {
                Task { await viewModel.skipQuestion() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.forward.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Skip")
                        .font(.hangsBody(15, weight: .medium))
                }
                .foregroundColor(Theme.Hangs.Colors.ink)
                .frame(height: 56)
                .padding(.horizontal, 20)
                .background(Capsule().fill(Theme.Hangs.Colors.bgCard))
                .overlay(Capsule().stroke(Theme.Hangs.Colors.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(isRecording || isProcessing)
            .opacity((isRecording || isProcessing) ? 0.45 : 1)
            .accessibilityIdentifier("question.skip")
        }
    }

    // MARK: - Typed-answer fallback (54.18)

    private var textInputToggle: some View {
        Button {
            showTextInput = true
            isTextFieldFocused = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "keyboard")
                    .font(.system(size: 12, weight: .semibold))
                Text("Type answer instead")
                    .font(.hangsBody(13, weight: .medium))
            }
            .foregroundColor(Theme.Hangs.Colors.muted)
            .padding(.vertical, 10)
            .padding(.horizontal, 18)
            .background(Capsule().fill(Theme.Hangs.Colors.bgCard))
            .overlay(Capsule().stroke(Theme.Hangs.Colors.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!canInteract)
        .opacity(canInteract ? 1 : 0.45)
        .accessibilityIdentifier("question.textInputToggle")
    }

    private var textInputRow: some View {
        HangsCard(padding: EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 8)) {
            HStack(spacing: 8) {
                TextField("Type your answer…", text: $textAnswer)
                    .font(.hangsBody(15))
                    .foregroundColor(Theme.Hangs.Colors.ink)
                    .frame(height: 40)
                    .focused($isTextFieldFocused)
                    .accessibilityIdentifier("question.textField")
                    .submitLabel(.send)
                    .onSubmit(submitTypedAnswer)

                Button(action: submitTypedAnswer) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(
                            Circle()
                                .fill(textAnswer.isEmpty ? Theme.Hangs.Colors.muted : Theme.Hangs.Colors.pink)
                        )
                }
                .disabled(textAnswer.isEmpty)
                .accessibilityIdentifier("question.textSubmit")
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Processing indicator (typed-answer path, 59.6)

    private var processingRow: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(Theme.Hangs.Colors.pink)
            Text("Evaluating…")
                .font(.hangsBody(15, weight: .medium))
                .foregroundColor(Theme.Hangs.Colors.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .accessibilityIdentifier("question.processingIndicator")
    }

    private func submitTypedAnswer() {
        guard !textAnswer.isEmpty else { return }
        let answer = textAnswer
        textAnswer = ""
        showTextInput = false
        Task { await viewModel.resubmitAnswer(answer) }
    }

    // MARK: - Derived

    private var isRecording: Bool { viewModel.quizState == .recording }

    private var canInteract: Bool { viewModel.quizState == .askingQuestion }

    private var isProcessing: Bool {
        viewModel.quizState == .processing || viewModel.quizState == .skipping
    }

    private var currentQuestionNumber: Int {
        let total = viewModel.currentSession?.maxQuestions ?? viewModel.settings.numberOfQuestions
        return min(viewModel.questionsAnswered + 1, max(total, 1))
    }

    private var quizStateName: String {
        switch viewModel.quizState {
        case .idle: return "idle"
        case .startingQuiz: return "startingQuiz"
        case .askingQuestion: return "askingQuestion"
        case .recording: return "recording"
        case .processing: return "processing"
        case .skipping: return "skipping"
        case .showingResult: return "showingResult"
        case .finished: return "finished"
        case .error: return "error"
        }
    }
}

#if DEBUG
    #Preview {
        QuestionView(viewModel: QuizViewModel.preview)
    }
#endif
