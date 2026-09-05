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

import SwiftUI

struct QuestionVoiceFooter: View {
    @ObservedObject var viewModel: QuizViewModel

    @Binding var showTextInput: Bool
    @Binding var textAnswer: String
    /// #171 Track E: what the driver just submitted, echoed by the evaluating
    /// overlay ("You said: …"). Written here for the typed path; the voice and MCQ
    /// paths write it in `QuestionView`.
    @Binding var submittedAnswer: String
    var isTextFieldFocused: FocusState<Bool>.Binding
    var compact: Bool = false

    var body: some View {
        VStack(spacing: 12) {
            // The recording surface. Pinned directly above the buttons so it
            // never scrolls away.
            if isRecording {
                transcriptCard
            }

            if showTextInput {
                textInputRow
            }

            // #122: light sweep strip — reserved in every phase so the stack
            // below never shifts; glows only during feedback.
            GlowSweepLine(phase: viewModel.voiceFeedbackPhase)
                .padding(.horizontal, 20)

            // #125 addendum + #131: the docked command bar, shown iff a command
            // window is armed (hidden during TTS and while recording — the
            // transcript card owns that state now).
            if !isRecording, let hint = viewModel.commandListenerHint {
                ListenBar(
                    mode: .command,
                    feedback: viewModel.voiceFeedbackPhase,
                    commandHint: hint,
                    // #131 Track F: the SE-class `compact` flag is now the slim size.
                    size: compact ? .slim : .full
                )
                .padding(.horizontal, 20)
                .transition(.opacity)
            }

            actionRow
                .padding(.horizontal, 20)
        }
    }

    // MARK: - Recording surface (Track C)

    /// The live transcript card, restyled to carry the listening affordance the
    /// pink answer bar used to duplicate: animated waveform + pink caption header
    /// + a pink hairline on the card itself. Shown from the first frame of
    /// `.recording`, so the batch (non-streaming) path also gets a visible "I am
    /// listening" surface — `LiveTranscriptView` renders its listening
    /// placeholder while the text is still empty.
    private var transcriptCard: some View {
        HangsCard(padding: EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.Hangs.Colors.pink)
                        .symbolEffect(.variableColor.iterative.dimInactiveLayers)
                        .accessibilityHidden(true)

                    Text("LISTENING — SAY YOUR ANSWER")
                        .font(.hangsMono(11, weight: .semibold))
                        .tracking(0.6)
                        .textCase(.uppercase)
                        .foregroundColor(Theme.Hangs.Colors.pink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }

                LiveTranscriptView(
                    text: viewModel.liveTranscript,
                    // Never "committed" while the card is on screen: the card only
                    // exists during `.recording`, and a committed transcript ends
                    // that state. Keeps the listening placeholder on the batch path.
                    isCommitted: false
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Hangs.Radius.card, style: .continuous)
                .stroke(Theme.Hangs.Colors.pink, lineWidth: 1)
        )
        .padding(.horizontal, 24)
        .accessibilityIdentifier("question.liveTranscript")
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
            title: isRecording ? "Stop" : "Record",
            icon: isRecording ? "stop.fill" : "mic.fill",
            // G1 (#83): action buttons deliberately modest so long question text
            // keeps as much room as possible.
            height: 48,
            countdownSecondsRemaining: viewModel.answerWindowRemaining,
            countdownTotal: viewModel.answerWindowTotal
        ) {
            Task { await viewModel.toggleRecording() }
        }
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

    private var skipButton: some View {
        Button {
            Task { await viewModel.skipQuestion() }
        } label: {
            // "play.forward.fill" is not an SF Symbol — it rendered nothing, which
            // only became visible once the word "Skip" stopped covering for it.
            iconChip("forward.end.fill", size: 16)
        }
        .buttonStyle(.plain)
        .disabled(isRecording || isProcessing)
        .opacity((isRecording || isProcessing) ? 0.45 : 1)
        .accessibilityLabel("Skip")
        .accessibilityIdentifier("question.skip")
    }

    /// The shared surface of the two icon-only controls: a circle as tall as the
    /// Record button beside it, so the row still reads as one strip.
    private func iconChip(_ systemName: String, size: CGFloat) -> some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: .semibold))
            .foregroundColor(Theme.Hangs.Colors.ink)
            .frame(width: 48, height: 48)
            .background(Circle().fill(Theme.Hangs.Colors.bgCard))
            .overlay(Circle().stroke(Theme.Hangs.Colors.hairline, lineWidth: 1))
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

    private var canInteract: Bool { viewModel.quizState == .askingQuestion }

    private var isProcessing: Bool {
        viewModel.quizState == .processing || viewModel.quizState == .skipping
    }
}
