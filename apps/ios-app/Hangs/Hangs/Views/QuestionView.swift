//
//  QuestionView.swift
//  Hangs
//
//  Hangs redesign question screen — terminal card + pink mic block.
//  Preserves MCQ, text input, thinking/answer timers, STT transcript.
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
        VStack(spacing: 0) {
            topBar
            headerTiles
            errorBanner

            if let question = viewModel.currentQuestion {
                if question.isMultipleChoice {
                    mcqBody(question: question)
                } else {
                    voiceBody(question: question)
                }
            } else {
                Spacer()
                ProgressView().tint(Theme.Hangs.Colors.accent)
                Spacer()
            }

            actionButtons
            HangsFooterBar(leading: "◢ REG.MARK.02", trailing: footerStatus)
        }
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
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

    // MARK: - Top bar (adaptive: blue during recording)

    private var topBar: some View {
        Group {
            if viewModel.quizState == .recording {
                HangsRecordingBar(liveLabel: "REC.ACTIVE • LIVE", timeLabel: recordingTimeString)
            } else {
                HangsStatusBar(
                    leading: "// SESSION.ACTIVE",
                    trailing: sessionTrailing,
                    leadingColor: Theme.Hangs.Colors.infoAccent,
                    trailingDotColor: sessionDotColor
                )
                HangsDivider()
            }
        }
    }

    private var sessionTrailing: String {
        switch viewModel.quizState {
        case .processing: return "◐ PROCESSING"
        case .askingQuestion: return "◐ REC-IDLE"
        default: return "◐ REC-IDLE"
        }
    }

    private var sessionDotColor: Color {
        viewModel.quizState == .processing ? Theme.Hangs.Colors.warning : Theme.Hangs.Colors.textSecondary
    }

    private var recordingTimeString: String {
        let seconds = recordingElapsed
        return String(format: "LIVE ● %02d:%02d", seconds / 60, seconds % 60)
    }

    private var recordingElapsed: Int {
        guard let start = recordingStartedAt else { return 0 }
        return max(0, Int(now.timeIntervalSince(start)))
    }

    // MARK: - Header tiles

    private var headerTiles: some View {
        HStack(spacing: 10) {
            headerTile(
                label: "QUESTION",
                value: questionProgressText,
                border: Theme.Hangs.Colors.infoAccent
            )
            Rectangle().fill(Theme.Hangs.Colors.divider).frame(height: 1)
            headerTile(
                label: "SCORE",
                value: String(format: "%.1f", viewModel.score),
                valueColor: Theme.Hangs.Colors.infoAccent,
                border: Theme.Hangs.Colors.divider
            )
            minimizeButton
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var questionProgressText: String {
        let total = viewModel.currentSession?.maxQuestions ?? 10
        let current = min(viewModel.questionsAnswered + 1, total)
        return String(format: "%02d / %02d", current, total)
    }

    private func headerTile(label: String, value: String, valueColor: Color = Theme.Hangs.Colors.textPrimary, border: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .foregroundColor(Theme.Hangs.Colors.textTertiary)
                .tracking(1.5)
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundColor(valueColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.Hangs.Colors.bgCard)
        .overlay(Rectangle().stroke(border, lineWidth: 1))
    }

    private var minimizeButton: some View {
        Button {
            if viewModel.canMinimize {
                viewModel.isMinimized = true
            }
        } label: {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.Hangs.Colors.textSecondary)
                .frame(width: 44, height: 44)
                .background(Theme.Hangs.Colors.bgCard)
                .overlay(Rectangle().stroke(Theme.Hangs.Colors.divider, lineWidth: 1))
        }
        .accessibilityLabel("Minimize")
        .accessibilityIdentifier("question.minimize")
        .disabled(!viewModel.canMinimize)
    }

    // MARK: - Error banner

    @ViewBuilder
    private var errorBanner: some View {
        if let error = viewModel.errorMessage {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(error).font(.system(size: 13))
            }
            .foregroundColor(Theme.Hangs.Colors.error)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Hangs.Colors.errorDim)
            .overlay(Rectangle().stroke(Theme.Hangs.Colors.error, lineWidth: 1))
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
            .accessibilityLabel("Error: \(error)")
        }
    }

    // MARK: - Voice body

    private func voiceBody(question: Question) -> some View {
        VStack(spacing: 14) {
            questionCard(question: question)
                .frame(maxHeight: .infinity)
                .layoutPriority(1)

            // Thinking / answer timer chips (preserve existing logic)
            if viewModel.thinkingTimeCountdown > 0 && viewModel.quizState == .askingQuestion {
                timerChip(label: "THINK", seconds: viewModel.thinkingTimeCountdown, color: Theme.Hangs.Colors.warning)
            }
            if viewModel.answerTimerCountdown > 0 && viewModel.quizState == .askingQuestion {
                timerChip(label: "ANSWER", seconds: viewModel.answerTimerCountdown, color: Theme.Hangs.Colors.accent)
            }

            // Live transcript
            if !viewModel.liveTranscript.isEmpty {
                LiveTranscriptView(text: viewModel.liveTranscript, isCommitted: !viewModel.isStreamingSTT)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.Hangs.Colors.bgCard)
                    .overlay(Rectangle().stroke(Theme.Hangs.Colors.infoAccent.opacity(0.5), lineWidth: 1))
                    .padding(.horizontal, 24)
            }

            waveformStrip

            micBlock

            if showTextInput { textInputRow }
        }
        .frame(maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    private func questionCard(question: Question) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("◢ HISTORY")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.Hangs.Colors.bg)
                    .tracking(2)
                Rectangle().fill(Theme.Hangs.Colors.bg.opacity(0.3)).frame(height: 1)
                Text(String(format: "Q.%03d", viewModel.questionsAnswered + 1))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.Hangs.Colors.bg)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.Hangs.Colors.infoAccent)

            VStack(alignment: .leading, spacing: 12) {
                Text("[ QUERY ]")
                    .font(.hangsMonoLabel)
                    .foregroundColor(Theme.Hangs.Colors.infoAccent)
                    .tracking(2)

                if question.hasImage {
                    ImageQuestionView(question: question)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        Text(question.question)
                            .font(.system(size: 28, weight: .black))
                            .tracking(-0.5)
                            .foregroundColor(Theme.Hangs.Colors.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("question.text")
                    }
                    .frame(minHeight: 160, maxHeight: .infinity)
                }

                HStack(spacing: 8) {
                    Circle()
                        .fill(hintDotColor)
                        .frame(width: 8, height: 8)
                    Text(hintText.uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(hintDotColor)
                        .tracking(2)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Theme.Hangs.Colors.bgCard)
        .overlay(Rectangle().stroke(Theme.Hangs.Colors.infoAccent, lineWidth: 1))
    }

    private var waveformStrip: some View {
        HStack(spacing: 6) {
            Text("◢")
                .font(.hangsMonoLabel)
                .foregroundColor(Theme.Hangs.Colors.infoAccent)
            Rectangle().fill(Theme.Hangs.Colors.divider).frame(height: 1)
            Text(waveformLabel)
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .foregroundColor(Theme.Hangs.Colors.textTertiary)
                .tracking(1.5)
        }
    }

    private var waveformLabel: String {
        switch viewModel.quizState {
        case .recording: return String(format: "LISTENING / %02d:%02d", recordingElapsed / 60, recordingElapsed % 60)
        case .processing: return "PROCESSING..."
        default: return "INPUT / VOICE"
        }
    }

    private var micBlock: some View {
        Button(action: { Task { await viewModel.toggleRecording() } }) {
            VStack(spacing: 14) {
                ZStack {
                    Rectangle()
                        .fill(Theme.Hangs.Colors.bgCard)
                        .frame(width: 136, height: 136)
                        .overlay(Rectangle().stroke(Theme.Hangs.Colors.accent, lineWidth: micBorderWidth))

                    Rectangle()
                        .fill(Theme.Hangs.Colors.accent)
                        .frame(width: 112, height: 112)
                        .modifier(ConditionalPulse(isActive: viewModel.quizState == .recording && !reduceMotion))

                    Image(systemName: "mic.fill")
                        .font(.system(size: micIconSize, weight: .bold))
                        .foregroundColor(Theme.Hangs.Colors.bg)
                }

                Text(micLabel)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.Hangs.Colors.accent)
                    .tracking(2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("question.micButton")
        .accessibilityLabel(micLabel)
    }

    private var micBorderWidth: CGFloat {
        viewModel.quizState == .recording ? 6 : 1.5
    }

    private var micIconSize: CGFloat {
        viewModel.quizState == .recording ? 60 : 46
    }

    private var micLabel: String {
        switch viewModel.quizState {
        case .recording: return "◢ TAP TO STOP"
        case .processing: return "◢ PROCESSING..."
        default: return "◢ PRESS TO SPEAK"
        }
    }

    private func timerChip(label: String, seconds: Int, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.hangsMonoLabel)
                .tracking(1.5)
            Text("\(seconds)s")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
        }
        .foregroundColor(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(color.opacity(0.15))
        .overlay(Rectangle().stroke(color, lineWidth: 1))
    }

    // MARK: - MCQ body

    private func mcqBody(question: Question) -> some View {
        VStack(spacing: 12) {
            questionCard(question: question)
                .frame(maxHeight: .infinity)
                .layoutPriority(1)
            MCQOptionPicker(
                options: question.sortedAnswerOptions,
                onSelect: { key, value in
                    Task { await viewModel.submitMCQAnswer(key: key, value: value) }
                }
            )
        }
        .frame(maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    // MARK: - Text input fallback

    private var textInputRow: some View {
        HStack(spacing: 8) {
            TextField("Type your answer...", text: $textAnswer)
                .font(.system(size: 15))
                .foregroundColor(Theme.Hangs.Colors.textPrimary)
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(Theme.Hangs.Colors.bgCard)
                .overlay(Rectangle().stroke(Theme.Hangs.Colors.divider, lineWidth: 1))
                .focused($isTextFieldFocused)
                .accessibilityIdentifier("question.textField")
                .submitLabel(.send)
                .onSubmit(submitTypedAnswer)

            Button(action: submitTypedAnswer) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Theme.Hangs.Colors.bg)
                    .frame(width: 44, height: 44)
                    .background(textAnswer.isEmpty ? Theme.Hangs.Colors.divider : Theme.Hangs.Colors.accent)
            }
            .disabled(textAnswer.isEmpty)
            .accessibilityIdentifier("question.textSubmit")
        }
    }

    private func submitTypedAnswer() {
        guard !textAnswer.isEmpty else { return }
        let answer = textAnswer
        textAnswer = ""
        showTextInput = false
        Task { await viewModel.resubmitAnswer(answer) }
    }

    // MARK: - Actions

    private var actionButtons: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                HangsGhostButton(title: "SKIP", icon: "forward.fill") {
                    Task { await viewModel.skipQuestion() }
                }
                .accessibilityIdentifier("question.skip")

                HangsGhostButton(title: "END QUIZ", icon: "xmark", color: Theme.Hangs.Colors.infoAccent) {
                    showEndQuizConfirmation = true
                }
                .accessibilityIdentifier("question.endQuiz")
            }
            .opacity(canInteract ? 1 : 0.5)

            // Secondary row: text input toggle + repeat + mute
            HStack(spacing: 10) {
                Button { showTextInput.toggle(); if showTextInput { isTextFieldFocused = true } } label: {
                    miniIcon(systemName: "keyboard")
                }
                .accessibilityLabel("Type answer")
                .accessibilityIdentifier("question.textInputToggle")
                .disabled(!canInteract)

                Button { Task { await viewModel.repeatQuestion() } } label: {
                    miniIcon(systemName: "speaker.wave.2")
                }
                .accessibilityLabel("Repeat question")
                .accessibilityIdentifier("question.repeat")
                .disabled(!canInteract)

                Button { viewModel.settings.isMuted.toggle() } label: {
                    miniIcon(systemName: viewModel.settings.isMuted ? "speaker.slash" : "speaker.wave.2.circle",
                             color: viewModel.settings.isMuted ? Theme.Hangs.Colors.error : Theme.Hangs.Colors.textSecondary)
                }
                .accessibilityLabel(viewModel.settings.isMuted ? "Unmute" : "Mute")
                .accessibilityIdentifier("question.mute")

                if viewModel.voiceCommandsAvailable {
                    VoiceCommandIndicator(state: viewModel.voiceCommandState)
                }

                Spacer()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func miniIcon(systemName: String, color: Color = Theme.Hangs.Colors.textSecondary) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(color)
            .frame(width: 40, height: 36)
            .overlay(Rectangle().stroke(Theme.Hangs.Colors.divider, lineWidth: 1))
    }

    // MARK: - Derived

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
            return "REC ● Recording... tap to stop"
        case .processing:
            return "Processing..."
        case .askingQuestion where viewModel.thinkingTimeCountdown > 0:
            return "Think... recording starts soon"
        case .askingQuestion where viewModel.answerTimerCountdown > 0:
            return "Recording starts automatically..."
        default:
            return "Tap mic to answer"
        }
    }

    private var hintDotColor: Color {
        switch viewModel.quizState {
        case .recording: return Theme.Hangs.Colors.accent
        case .processing: return Theme.Hangs.Colors.warning
        default: return Theme.Hangs.Colors.accent
        }
    }

    private var canInteract: Bool {
        viewModel.quizState == .askingQuestion
    }

    private var footerStatus: String {
        switch viewModel.quizState {
        case .recording: return "AUDIO: REC ● OK"
        case .processing: return "EVAL: PENDING ● WAIT"
        default: return "LAT: OK"
        }
    }
}

// MARK: - Conditional pulse modifier

private struct ConditionalPulse: ViewModifier {
    let isActive: Bool
    @State private var pulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isActive && pulsing ? 1.05 : 1.0)
            .opacity(isActive && pulsing ? 0.7 : 1.0)
            .animation(isActive ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: pulsing)
            .onAppear { pulsing = isActive }
            .onChange(of: isActive) { _, newValue in pulsing = newValue }
    }
}

#if DEBUG
#Preview {
    QuestionView(viewModel: QuizViewModel.preview)
}
#endif
