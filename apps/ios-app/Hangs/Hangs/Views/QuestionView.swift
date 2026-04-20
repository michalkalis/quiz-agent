//
//  QuestionView.swift
//  Hangs
//
//  Hangs redesign question screen — cream bg, pink mic block, editorial prompt.
//  Preserves MCQ, text input, thinking/answer timers, STT transcript, voice cmds.
//

import Combine
import SwiftUI

struct QuestionView: View {
    @ObservedObject var viewModel: QuizViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showEndQuizConfirmation = false
    @State private var showTextInput = false
    @State private var textAnswer = ""
    @State private var recordingStartedAt: Date?
    @State private var now = Date()
    @FocusState private var isTextFieldFocused: Bool

    private let clockTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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

            if let error = viewModel.errorMessage {
                errorBanner(error)
                    .padding(.top, 80)
            }
        }
        .sensoryFeedback(.start, trigger: viewModel.quizState == .recording)
        .onReceive(clockTimer) { _ in now = Date() }
        .onChange(of: viewModel.quizState) { _, newState in
            recordingStartedAt = (newState == .recording) ? Date() : nil
        }
        .interactiveMinimize(
            isMinimized: $viewModel.isMinimized,
            canMinimize: viewModel.canMinimize
        )
        .sheet(isPresented: $viewModel.showAnswerConfirmation, onDismiss: {
            viewModel.handleAnswerConfirmationDismissed()
        }) {
            AnswerConfirmationView(
                isProcessing: viewModel.quizState == .processing && viewModel.transcribedAnswer.isEmpty,
                transcribedAnswer: viewModel.transcribedAnswer,
                autoConfirmCountdown: viewModel.autoConfirmCountdown,
                autoConfirmEnabled: viewModel.settings.autoConfirmEnabled,
                autoConfirmTotal: Config.autoConfirmDelaySecs,
                onConfirm: { Task { await viewModel.confirmAnswer() } },
                onReRecord: { viewModel.rerecordAnswer() },
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
            supportRow
        }
    }

    private var counterString: String {
        if isRecording {
            let seconds = recordingElapsed
            return String(format: "● %d:%02d", seconds / 60, seconds % 60)
        }
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
        .foregroundColor(Theme.Hangs.Colors.pink)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.Hangs.Colors.pinkSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.Hangs.Colors.pink.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, 24)
        .accessibilityLabel("Error: \(error)")
    }

    // MARK: - Voice body

    private func voiceBody(question: Question) -> some View {
        VStack(spacing: 0) {
            fixedQuestionHeader(question: question)

            // Question scrolls full-height; mic floats over the bottom so the
            // question text can extend underneath the translucent halos.
            ZStack(alignment: .bottom) {
                scrollableQuestionContent(question: question)

                VStack(spacing: 6) {
                    if isRecording && !viewModel.liveTranscript.isEmpty {
                        transcriptCard
                    }
                    floatingMicRow
                }
                .padding(.bottom, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showTextInput { textInputRow }

            chipActionRow

            footerCTA
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Fixed question header (category label + hint)

    private func fixedQuestionHeader(question: Question) -> some View {
        HangsSectionLabel(
            text: question.category.uppercased(),
            color: isRecording ? Theme.Hangs.Colors.blue : Theme.Hangs.Colors.pink
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    // MARK: - Scrollable question body (text or image)

    private func scrollableQuestionContent(question: Question) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                if question.hasImage {
                    ImageQuestionView(question: question)
                } else {
                    HangsQuestionPrompt(
                        text: question.question,
                        barColor: isRecording ? Theme.Hangs.Colors.pink : Theme.Hangs.Colors.blue,
                        textFont: .hangsQuestion
                    )
                    .accessibilityIdentifier("question.text")
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Transcript card

    private var transcriptCard: some View {
        HangsCard(padding: EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)) {
            VStack(alignment: .leading, spacing: 10) {
                HangsSectionLabel(text: "LISTENING", color: Theme.Hangs.Colors.pink)
                LiveTranscriptView(
                    text: viewModel.liveTranscript,
                    isCommitted: !viewModel.isStreamingSTT
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 4)
    }

    // MARK: - Support row (timers + waveform + voice command hint)

    @ViewBuilder
    private var supportRow: some View {
        let showThink = viewModel.thinkingTimeCountdown > 0 && viewModel.quizState == .askingQuestion
        let showAnswer = viewModel.answerTimerCountdown > 0 && viewModel.quizState == .askingQuestion
        if showThink || showAnswer || isRecording {
            HStack(spacing: 8) {
                if showThink {
                    timerChip(label: "THINK", seconds: viewModel.thinkingTimeCountdown, color: Theme.Hangs.Colors.blue)
                }
                if showAnswer {
                    timerChip(label: "ANSWER", seconds: viewModel.answerTimerCountdown, color: Theme.Hangs.Colors.pink)
                }
                if isRecording {
                    waveformStrip
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28)
        }
    }

    private func timerChip(label: String, seconds: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.hangsMono(10, weight: .semibold))
                .tracking(1.5)
            Text("\(seconds)s")
                .font(.hangsMono(12, weight: .semibold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.12)))
        .overlay(Capsule().stroke(color.opacity(0.4), lineWidth: 1))
    }

    private var waveformStrip: some View {
        HStack(spacing: 3) {
            ForEach(0..<12, id: \.self) { i in
                Capsule()
                    .fill(Theme.Hangs.Colors.pink)
                    .frame(width: 2, height: waveBarHeight(i))
            }
        }
        .frame(height: 18)
    }

    private func waveBarHeight(_ i: Int) -> CGFloat {
        let heights: [CGFloat] = [6, 10, 14, 8, 16, 12, 18, 10, 14, 8, 12, 6]
        return heights[i % heights.count]
    }

    // MARK: - Floating mic (centered over the question content)

    private var floatingMicRow: some View {
        HangsMicBlock(mode: isRecording ? .listening : .tap, compact: true) {
            Task { await viewModel.toggleRecording() }
        }
        .accessibilityIdentifier("question.micButton")
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var micHint: String {
        switch viewModel.quizState {
        case .recording:
            return #"say "stop" when finished"#
        case .processing:
            return "processing…"
        case .askingQuestion where viewModel.thinkingTimeCountdown > 0:
            return "think… recording starts soon"
        case .askingQuestion where viewModel.answerTimerCountdown > 0:
            return "recording starts automatically…"
        default:
            return #"or say "start" to begin"#
        }
    }

    // MARK: - Chip action row (repeat / keyboard / mute + voice hint)

    private var chipActionRow: some View {
        HStack(spacing: 10) {
            navChip(systemName: "speaker.wave.2",
                    label: "Repeat question",
                    identifier: "question.repeat",
                    isEnabled: canInteract) {
                Task { await viewModel.repeatQuestion() }
            }

            navChip(systemName: "keyboard",
                    label: "Type answer",
                    identifier: "question.textInputToggle",
                    isEnabled: canInteract) {
                showTextInput.toggle()
                if showTextInput { isTextFieldFocused = true }
            }

            navChip(systemName: viewModel.settings.isMuted ? "speaker.slash" : "speaker.wave.2.circle",
                    label: viewModel.settings.isMuted ? "Unmute" : "Mute",
                    identifier: "question.mute",
                    tint: viewModel.settings.isMuted ? Theme.Hangs.Colors.pink : Theme.Hangs.Colors.ink,
                    isEnabled: true) {
                viewModel.settings.isMuted.toggle()
            }

            Spacer(minLength: 8)

            Text(micHint)
                .font(.hangsBody(12))
                .foregroundColor(Theme.Hangs.Colors.muted)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    private func navChip(systemName: String,
                         label: String,
                         identifier: String,
                         tint: Color = Theme.Hangs.Colors.ink,
                         isEnabled: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.white))
                .hangsShadow(Theme.Hangs.Shadow.navChip)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    // MARK: - Footer CTA

    @ViewBuilder
    private var footerCTA: some View {
        Group {
            switch viewModel.quizState {
            case .recording:
                HangsPrimaryButton(title: "Stop recording",
                                   icon: "stop.fill",
                                   height: 60,
                                   isDestructive: true) {
                    Task { await viewModel.toggleRecording() }
                }
                .accessibilityIdentifier("question.stopRecording")
            case .processing:
                HangsPrimaryButton(title: "Processing…",
                                   icon: nil,
                                   isLoading: true,
                                   height: 60) {}
            default:
                HangsSecondaryButton(title: "Skip question",
                                     icon: "forward.fill",
                                     height: 54) {
                    Task { await viewModel.skipQuestion() }
                }
                .accessibilityIdentifier("question.skip")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 28)
    }

    // MARK: - MCQ body

    private func mcqBody(question: Question) -> some View {
        VStack(spacing: 0) {
            fixedQuestionHeader(question: question)

            scrollableQuestionContent(question: question)

            MCQOptionPicker(
                options: question.sortedAnswerOptions,
                onSelect: { key, value in
                    Task { await viewModel.submitMCQAnswer(key: key, value: value) }
                }
            )
            .padding(.top, 8)

            chipActionRow

            HangsSecondaryButton(title: "Skip question",
                                 icon: "forward.fill",
                                 height: 54) {
                Task { await viewModel.skipQuestion() }
            }
            .accessibilityIdentifier("question.skip")
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Text input fallback

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

    private func submitTypedAnswer() {
        guard !textAnswer.isEmpty else { return }
        let answer = textAnswer
        textAnswer = ""
        showTextInput = false
        Task { await viewModel.resubmitAnswer(answer) }
    }

    // MARK: - Derived

    private var isRecording: Bool { viewModel.quizState == .recording }

    private var canInteract: Bool {
        viewModel.quizState == .askingQuestion
    }

    private var recordingElapsed: Int {
        guard let start = recordingStartedAt else { return 0 }
        return max(0, Int(now.timeIntervalSince(start)))
    }
}

#if DEBUG
#Preview {
    QuestionView(viewModel: QuizViewModel.preview)
}
#endif
