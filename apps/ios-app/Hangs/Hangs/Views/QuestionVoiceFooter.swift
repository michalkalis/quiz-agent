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
//     expiry, and it lives IN the Record button (`HangsPrimaryButton`'s #108B
//     fill + seconds chip, the same treatment as Confirm / Next question). The
//     Stop state keeps it running: `viewModel.answerWindowRemaining` switches
//     from the think/answer window to the recording window without ever going
//     blank, so nothing the driver does — tapping Record, saying "start",
//     replaying, a state wobble — makes the number disappear.
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
    @ObservedObject var viewModel: QuizViewModel

    @Binding var showTextInput: Bool
    @Binding var textAnswer: String
    /// What the driver just submitted, echoed by the confirmation sheet while the
    /// answer is graded ("You said: …"). Written here for the typed path; the
    /// voice and MCQ paths write it in `QuestionView`.
    @Binding var submittedAnswer: String
    var isTextFieldFocused: FocusState<Bool>.Binding
    var compact: Bool = false

    var body: some View {
        VStack(spacing: 12) {
            if showTextInput {
                textInputRow
            }

            // #122: light sweep strip — reserved in every phase so the stack
            // below never shifts; glows only during feedback.
            GlowSweepLine(phase: viewModel.voiceFeedbackPhase)
                .padding(.horizontal, 20)

            // #179 D1: the docked bar, in whichever of the four states the quiz
            // is in — never gated on the command window any more, because two of
            // those states listen for no command at all and the bar still has to
            // be there. The words inside it are what the arming gates.
            if let phase = listenPhase {
                QuestionListenBar(
                    phase: phase,
                    feedback: viewModel.voiceFeedbackPhase,
                    showsWords: showsCommandWords,
                    // #131 Track F: the SE-class `compact` flag is now the slim size.
                    size: compact ? .slim : .full,
                    language: viewModel.commandLanguage
                )
                .padding(.horizontal, 20)
                .transition(.opacity)
            }

            actionRow
                .padding(.horizontal, 20)
        }
    }

    // MARK: - Action row (Record · Type · Skip)

    private var actionRow: some View {
        HStack(spacing: 10) {
            recordButton
            typeButton
            skipButton
        }
    }

    /// Manual override (54.3): `toggleRecording` starts recording immediately from
    /// `.askingQuestion` and stops + submits from `.recording`. Auto-record still
    /// fires on its own via `startRecordingOrTimer()`.
    ///
    /// Track B: this is where the countdown lives now. `answerWindowTotal` is 0
    /// when nothing is running, which is exactly `HangsPrimaryButton`'s "no
    /// countdown" contract — the fill and the seconds chip simply don't render.
    private var recordButton: some View {
        HangsPrimaryButton(
            // #174: the typed-answer path never opens the confirmation sheet, so
            // this button IS its evaluating state (the full-screen overlay that
            // used to cover the footer is gone). `isLoading` also disables it.
            // #174 (founder 2026-09-09): "Start" — the title IS the voice command
            // that opens the mic, on Home and here alike.
            title: isEvaluating ? "Evaluating…" : (isRecording ? "Stop" : "Start"),
            icon: isEvaluating ? nil : (isRecording ? "stop.fill" : "play.fill"),
            isLoading: isEvaluating,
            // G1 (#83): action buttons deliberately modest so long question text
            // keeps as much room as possible.
            height: 48,
            countdownSecondsRemaining: viewModel.answerWindowRemaining,
            countdownTotal: viewModel.answerWindowTotal
        ) {
            Task { await viewModel.toggleRecording() }
        }
        // #174 review: during an in-flight skip the footer stays mounted, so
        // gate the CTA on `.skipping` too — a tap there is a silent no-op.
        .disabled(isSkipping)
        .opacity(isSkipping ? 0.45 : 1)
        // #122: teal ring while a matched-command glow is live.
        .overlay {
            if viewModel.voiceFeedbackPhase == .matched {
                Capsule()
                    .inset(by: -2)
                    .stroke(Theme.Hangs.Colors.accentTeal.opacity(0.30), lineWidth: 4)
            }
        }
        .accessibilityIdentifier(isRecording ? "question.stop" : "question.record")
    }

    /// Typed-answer fallback (#54 task 54.18). #171 Track C1: icon-only. The words
    /// "Type" / "Skip" sized these two buttons off the localized string, and in
    /// Slovak ("Písať" / "Preskočiť" beside "Nahrávať") nothing was left for the
    /// Record button — its seconds pill was what got clipped. A square glyph is the
    /// same width in every language; the word survives as the accessibility label,
    /// so VoiceOver still says "Type".
    private var typeButton: some View {
        Button {
            showTextInput = true
            isTextFieldFocused.wrappedValue = true
        } label: {
            iconChip("keyboard", size: 17)
        }
        .buttonStyle(.plain)
        .disabled(!canInteract || showTextInput)
        .opacity((canInteract && !showTextInput) ? 1 : 0.45)
        .accessibilityLabel("Type")
        .accessibilityIdentifier("question.textInputToggle")
    }

    /// #174 (founder 2026-09-09): the word is back — "Skip" IS the voice command,
    /// and a driver learns it by reading the button. #171 had made this icon-only
    /// because "Preskočiť" beside "Nahrávať" left the Record button no room; the
    /// imperative pair ("Preskoč" beside "Štart") is short enough to share the row.
    ///
    /// #179 D3: and it is the SAME capsule the MCQ screen draws now — one shape
    /// and one word for the escape hatch, at the 48pt height that keeps this row
    /// reading as one strip.
    private var skipButton: some View {
        QuestionSkipButton(
            isSkipping: isSkipping,
            isDisabled: isRecording || isProcessing,
            height: 48
        ) {
            Task { await viewModel.skipQuestion() }
        }
    }

    /// The surface of the icon-only Type control: a circle as tall as the Record
    /// button beside it, so the row still reads as one strip. (#179 D3 moved the
    /// skip capsule out to `QuestionSkipButton`, which now owns its own chrome.)
    private func iconChip(_ systemName: String, size: CGFloat) -> some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: .semibold))
            .foregroundColor(Theme.Hangs.Colors.ink)
            .tint(Theme.Hangs.Colors.ink)
            .frame(width: 48, height: 48)
            .background(Capsule().fill(Theme.Hangs.Colors.bgCard))
            .overlay(Capsule().stroke(Theme.Hangs.Colors.hairline, lineWidth: 1))
    }

    // MARK: - Typed answer

    private var textInputRow: some View {
        HangsCard(padding: EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 8)) {
            HStack(spacing: 8) {
                TextField("Type your answer…", text: $textAnswer)
                    .font(.hangsBody(15))
                    .foregroundColor(Theme.Hangs.Colors.ink)
                    .frame(height: 40)
                    .focused(isTextFieldFocused)
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
        submittedAnswer = answer
        textAnswer = ""
        showTextInput = false
        Task { await viewModel.resubmitAnswer(answer) }
    }

    // MARK: - Derived

    private var isRecording: Bool { viewModel.quizState == .recording }

    /// #179 D1: the one state model — the same call the MCQ body makes.
    private var listenPhase: QuestionListenPhase? {
        QuestionListenPhase.current(
            quizState: viewModel.quizState,
            answerWindowRemaining: viewModel.answerWindowRemaining,
            answerWindowTotal: viewModel.answerWindowTotal,
            answerKind: .open
        )
    }

    /// A chip is a promise the word will be heard: Settings toggle AND an armed
    /// listener. The bar itself no longer depends on either.
    private var showsCommandWords: Bool {
        viewModel.showsVoiceHints && viewModel.commandListenerHint != nil
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
