//
//  QuestionVoiceFooter.swift
//  Hangs
//
//  The pinned bottom stack of the voice-answer question screen, extracted from
//  QuestionView in #131 so the screen's two biggest changes live in one readable
//  place instead of growing an already-900-line view.
//
//  Founder spec, 2026-07-29 TestFlight test:
//
//   - Track B — ONE countdown, from the end of the question read to submit or
//     expiry. (#188 G11 moved it from the Record button into the listen bar,
//     see `recordButton`.) It used to live IN the Record button (`HangsPrimaryButton`'s #108B
//     fill + seconds chip, the same treatment as Confirm / Next question). The
//     Stop state keeps it running: `viewModel.answerWindowRemaining` switches
//     from the think/answer window to the recording window without ever going
//     blank, so nothing the driver does — tapping Record, saying "start",
//     replaying, a state wobble — makes the number disappear.
//
//   - #224 (canvas E1): Answer and Type are equal labelled buttons side by side,
//     Skip is an icon-only round control at the end.
//
//   - Track C — the footer row reads Record · Type · Skip. "Type answer instead"
//     lost its floating slot in the audio strip and became a compact secondary
//     button next to the other two.
//
//   - Track C — while recording there is NO pink "LISTENING — SAY YOUR ANSWER"
//     bar. The transcript card IS the recording surface, so it carries the
//     listening affordance itself (waveform + pink accent header) and appears the
//     moment recording starts, not when the first STT partial arrives.
//
//  #179 D1 (founder pick 2026-09-15) REVERSES that last point. The bar is now the
//  ONE state surface of the question screen and it holds its slot through all
//  four states — reading, thinking, listening, evaluating — identically on MCQ
//  and here; a bar that disappeared mid-answer is what made the screen read as
//  frozen.
//
//  #181 (founder, TF build 62, 2026-09-15): the transcript card above the bar is
//  GONE. It sat empty on the batch path and for the first seconds of streaming,
//  and the confirmation sheet shows what was heard anyway — so it was a blank
//  pink box that read as "the app is not hearing me". The bar is the only
//  recording surface now.
//

import SwiftUI

struct QuestionVoiceFooter: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject var viewModel: QuizViewModel

    @Binding var showTextInput: Bool
    @Binding var textAnswer: String
    /// What the driver just submitted, echoed by the confirmation sheet while the
    /// answer is graded ("You said: …"). Written here for the typed path; the
    /// voice and MCQ paths write it in `QuestionView`.
    @Binding var submittedAnswer: String
    var isTextFieldFocused: FocusState<Bool>.Binding
    var compact: Bool = false

    /// #194 canvas: the footer shares the screen's 16pt edge.
    private static let gutter = Theme.Hangs.Spacing.md
    private static let pairTypeCap = DynamicTypeSize.xLarge
    /// Glyph size of the send control.
    private static let glyphSize: CGFloat = 17
    /// Bg-Typed: the typed answer reads larger than body text.
    private static let typedAnswerSize: CGFloat = 20

    /// #194 R-Question: the row is 56pt tall; a short container keeps the
    /// older 48pt so the question keeps its room.
    private var rowHeight: CGFloat { compact ? QuestionSkipButton.compactRowHeight : QuestionSkipButton.rowHeight }

    var body: some View {
        VStack(spacing: Theme.Hangs.Spacing.sm) {
            // 2026-11-21: once a month, the voice answers are used up. Shown in
            // both states, because Answer now opens the typed field.
            if viewModel.showsVoiceLimitNotice {
                VoiceLimitNotice(onPlus: viewModel.openPaywallFromVoiceLimitNotice)
                    .padding(.horizontal, Self.gutter)
                    .transition(.opacity)
            }

            // Silent mode (founder 2026-11-22): the typed field is the only way
            // to answer, so it is open from the start and there is no Answer.
            if showTextInput || viewModel.isSilentMode {
                // TF build 90 (founder): typing is its own calm state. The field,
                // send and Skip (F2) sit directly on the keyboard; only the
                // countdown stays above them, standing still while typing (F3).
                if let stripPhase {
                    listenBar(stripPhase)
                }
                textInputRow
            } else {
                // #122: light sweep strip, glows only during feedback.
                GlowSweepLine(phase: viewModel.voiceFeedbackPhase)
                    .padding(.horizontal, Self.gutter)

                // TF build 90: the strip shows only what the player needs
                // (`QuestionListenPhase.strip`). Its slot is reserved, so the
                // question never moves when it comes and goes.
                ZStack {
                    if let stripPhase {
                        listenBar(stripPhase)
                            .transition(.opacity)
                    } else if let heard = viewModel.commandHeard {
                        // "What the app hears" where the strip is hidden.
                        CommandHeardLine(heard: heard, language: viewModel.commandLanguage)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: QuestionListenBar.slotHeight(size: barSize))
                .animation(.easeInOut(duration: 0.25), value: stripPhase == nil)
                .animation(.easeInOut(duration: 0.25), value: viewModel.commandHeard == nil)

                actionRow
                    .padding(.horizontal, Self.gutter)
            }
        }
    }

    /// #179 D1: the docked bar in whichever state the strip shows. The
    /// command words are never offered (TF build 90): commands are heard
    /// unreliably, so the screen does not advertise them.
    private func listenBar(_ phase: QuestionListenPhase) -> some View {
        QuestionListenBar(
            phase: phase,
            feedback: viewModel.voiceFeedbackPhase,
            recognizingWord: viewModel.recognizingWord,
            heard: viewModel.commandHeard,
            showsWords: false,
            size: barSize,
            language: viewModel.commandLanguage,
            speechHeard: viewModel.isHearingAnswer,
            inputLevel: viewModel.recordingInputLevel,
            // #188 G11: the recording window, moved out of the Stop button.
            answerRemaining: viewModel.answerWindowRemaining,
            answerNote: viewModel.answerBarNote,
            commandsAccessory: viewModel.commandsAccessory(for: phase),
            onTurnOnCommands: turnOnCommands,
            onOpenSettings: openSystemSettings
        )
        .padding(.horizontal, Self.gutter)
    }

    /// #131 Track F: the SE-class `compact` flag is the slim size.
    private var barSize: ListenBar.Size { compact ? .slim : .full }

    // MARK: - Action row (Record · Type · Skip)

    private var actionRow: some View {
        HStack(spacing: Theme.Hangs.Spacing.xs) {
            recordButton
            typeButton
            skipButton
        }
        // Answer and Type read as a pair, so both labels scale together: capped at
        // the size where "Odpovedz" still fits beside "Napíš" without shrinking.
        .dynamicTypeSize(...Self.pairTypeCap)
    }

    /// Manual override (54.3): `toggleRecording` starts recording immediately from
    /// `.askingQuestion` and stops + submits from `.recording`. Auto-record still
    /// fires on its own via `startRecordingOrTimer()`.
    ///
    /// #188 G11 (founder audit D13 + M8) reverses #131 Track B here: the
    /// countdown is NOT in this button any more. It showed twice ("Štart 23s"
    /// under a bar counting the same seconds) and the pair truncated at large
    /// text. The listen bar above is the one home of state, countdown and
    /// "Processing…"; this button says only its action.
    private var recordButton: some View {
        HangsPrimaryButton(
            // #194 (founder 2026-10-08): "Answer" with a mic says what the
            // button does; the voice command that opens the mic stays "start"
            // and the listen bar's chips keep teaching it.
            title: isRecording ? "Stop" : "Answer",
            icon: isRecording ? "stop.fill" : "mic.fill",
            // #174: the typed-answer path never opens the confirmation sheet, so
            // this button IS its evaluating state — a spinner alone (G11), the
            // word "Processing…" is the bar's. `isLoading` also disables it.
            isLoading: isEvaluating,
            loadingStyle: .spinnerOnly,
            height: rowHeight,
            // #198 (canvas Bg-Question): Stop is pink while the mic is open,
            // matching the answer bar; "Answer" stays the ink action.
            tint: isRecording ? Theme.Hangs.Colors.listenStrong : nil,
            singleLineTitle: true
        ) {
            // 2026-11-21: with the voice answers used up, Answer opens the
            // typed field instead of a mic the server would refuse.
            if viewModel.isVoiceAllowanceSpent {
                openTypedAnswer()
            } else {
                Task { await viewModel.toggleRecording() }
            }
        }
        // #174 review: during an in-flight skip the footer stays mounted, so
        // gate the CTA on `.skipping` too — a tap there is a silent no-op.
        // #188 G14: the button draws its own disabled state now; an extra
        // opacity on top would fade it twice.
        .disabled(isSkipping)
        // #122: teal ring while a matched-command glow is live.
        .overlay {
            if viewModel.voiceFeedbackPhase == .matched {
                Capsule()
                    .inset(by: -2)
                    .stroke(Theme.Hangs.Colors.liveAccent.opacity(0.30), lineWidth: 4)
            }
        }
        .accessibilityIdentifier(isRecording ? "question.stop" : "question.record")
    }

    /// Typed-answer fallback (#54 task 54.18). #224 (canvas E1): the same weight as
    /// the Answer button beside it, a labelled glass button, so typing is a
    /// first-class way to answer and not a hidden icon.
    private var typeButton: some View {
        Button(action: openTypedAnswer) {
            Label("Type", systemImage: "keyboard")
                .font(.hangsButton)
                .lineLimit(1)
                .minimumScaleFactor(HangsButtonTitle.singleLineMinimumScale)
                .foregroundColor(Theme.Hangs.Colors.ink)
                .frame(maxWidth: .infinity)
                .frame(height: rowHeight)
                // Canvas E1: a visible pill, same height and width as Answer.
                .background(Capsule().fill(Theme.Hangs.Colors.bgCard))
                .overlay(Capsule().strokeBorder(Theme.Hangs.Colors.subtleBorder, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!canInteract || showTextInput)
        .opacity((canInteract && !showTextInput) ? 1 : 0.45)
        .accessibilityIdentifier("question.textInputToggle")
    }

    /// #224 (canvas E1): icon only, its word is the accessibility label and the
    /// voice command (#174). The same round control the MCQ screen draws (#179 D3).
    private var skipButton: some View {
        QuestionSkipButton(
            isSkipping: isSkipping,
            isDisabled: isRecording || isProcessing,
            height: rowHeight
        ) {
            Task { await viewModel.skipQuestion() }
        }
    }

    // MARK: - Typed answer

    /// #194 Bg-Typed: a white capsule field with the ink send button beside it,
    /// under the listen bar. Founder F2 (TF build 90): Skip stays beside them,
    /// players used it while typing.
    private var textInputRow: some View {
        HStack(spacing: Theme.Hangs.Spacing.xs) {
            TextField("Type your answer…", text: $textAnswer)
                .font(.hangsBody(Self.typedAnswerSize, weight: .semibold))
                .foregroundColor(Theme.Hangs.Colors.ink)
                .focused(isTextFieldFocused)
                .accessibilityIdentifier("question.textField")
                .submitLabel(.send)
                .onSubmit(submitTypedAnswer)
                .limitLength($textAnswer, to: TextInputLimit.answer)
                .padding(.horizontal, Theme.Hangs.Spacing.lg)
                .frame(maxWidth: .infinity, minHeight: rowHeight)
                .background(Capsule().fill(Theme.Hangs.Colors.bgCard))
                .overlay(Capsule().strokeBorder(Theme.Hangs.Colors.ink, lineWidth: 1.5))

            Button(action: submitTypedAnswer) {
                Image(systemName: "arrow.up")
                    .font(.hangsBody(Self.glyphSize, weight: .bold))
                    .foregroundColor(textAnswer.isEmpty ? Theme.Hangs.Colors.muted : Theme.Hangs.Colors.textOnAction)
                    .frame(width: QuestionSkipButton.compactRowHeight, height: QuestionSkipButton.compactRowHeight)
                    .background(
                        Circle()
                            .fill(textAnswer.isEmpty ? Theme.Hangs.Colors.mutedBorder : Theme.Hangs.Colors.action)
                    )
            }
            // The field stays up while a silent answer is graded; one send.
            .disabled(textAnswer.isEmpty || !canInteract)
            .accessibilityIdentifier("question.textSubmit")

            skipButton
        }
        .padding(.horizontal, Self.gutter)
    }

    private func openTypedAnswer() {
        viewModel.beginTypingAnswer()
        showTextInput = true
        isTextFieldFocused.wrappedValue = true
    }

    private func submitTypedAnswer() {
        guard !textAnswer.isEmpty, canInteract else { return }
        let answer = textAnswer
        submittedAnswer = answer
        textAnswer = ""
        showTextInput = false
        Task { await viewModel.resubmitAnswer(answer) }
    }

    // MARK: - Commands (#237)

    private func turnOnCommands() {
        Task { await viewModel.turnOnVoiceCommandsFromListenBar() }
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }

    // MARK: - Derived

    private var isRecording: Bool { viewModel.quizState == .recording }

    /// #179 D1: the one state model — the same call the MCQ body makes.
    private var stripPhase: QuestionListenPhase? {
        viewModel.questionStripPhase(QuestionListenPhase.current(
            quizState: viewModel.quizState,
            answerWindowRemaining: viewModel.answerWindowRemaining,
            answerWindowTotal: viewModel.answerWindowTotal,
            answerKind: .open,
            isReadingQuestion: viewModel.isReadingQuestion
        ))
    }

    private var canInteract: Bool { viewModel.quizState == .askingQuestion }

    private var isProcessing: Bool {
        viewModel.quizState == .processing || viewModel.quizState == .skipping
    }

    private var isSkipping: Bool { viewModel.quizState == .skipping }

    /// An answer is being graded with no confirmation sheet in front of this
    /// footer — the typed path, and (invisibly, behind the sheet) the voice one.
    private var isEvaluating: Bool { viewModel.quizState == .processing }
}
