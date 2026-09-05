//
//  AnswerConfirmationView.swift
//  Hangs
//
//  Modal sheet for confirming or re-recording a voice answer. Editorial
//  Hangs styling: cream bg, pink mono caps label, pink vertical rule + big
//  display typography for the transcript, and Hangs pill CTAs. The auto-
//  confirm countdown drains inside the Confirm button itself (#108B),
//  mirroring the auto-advance pattern on ResultView.
//

import SwiftUI

struct AnswerConfirmationView: View {
    let isProcessing: Bool
    @Binding var transcribedAnswer: String
    let autoConfirmCountdown: Int
    let autoConfirmEnabled: Bool
    let autoConfirmTotal: Int
    let onConfirm: () -> Void
    let onReRecord: () -> Void
    var onEditingBegan: (() -> Void)? = nil
    var onCancelEditing: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    /// #77/#96 P2: the "LISTENING FOR COMMANDS" hint (pen `s49sd`), or nil when
    /// the confirmation command window isn't armed. Supplied by the presenter.
    var commandHint: String? = nil
    /// #122 Variant C: transient match/miss tint for the listening bar.
    var commandFeedback: VoiceFeedbackPhase = .idle
    /// #171 Track I: the MCQ option a spoken answer resolved to, pre-formatted
    /// as "A · Kocka". Shown above the transcript so the driver can check the
    /// match — the field itself holds the option VALUE, which is what gets
    /// graded — and nil on every non-MCQ confirmation.
    var matchedOption: String? = nil
    /// #171 Track D: the quiz is paused ON THIS SHEET — the countdown is gone
    /// (the presenter zeroes it), the listener is down, and the header says so.
    var isPaused: Bool = false
    /// Toggles pause/resume. Nil hides the control entirely (previews, MCQ tap
    /// paths that never present a pausable sheet).
    var onTogglePause: (() -> Void)? = nil

    @State private var isEditing = false
    @FocusState private var editFocused: Bool

    var body: some View {
        ZStack {
            Theme.Hangs.Colors.bg.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                if isProcessing {
                    processingBody
                } else {
                    transcriptBody
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
        .presentationBackground(Theme.Hangs.Colors.bg)
        .interactiveDismissDisabled(true)
    }

    // MARK: - Transcript state

    private var transcriptBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                HangsSectionLabel(text: "YOU SAID", color: Theme.Hangs.Colors.pink)
                if isPaused {
                    // Named, not merely implied by a missing countdown: a
                    // vanished chip reads as "auto-confirm off", not "paused".
                    HangsSectionLabel(text: "PAUSED", color: Theme.Hangs.Colors.blue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Theme.Hangs.Colors.neutralSoft))
                        .accessibilityIdentifier("confirmation.paused")
                }
                Spacer()
                if isEditing {
                    Button {
                        cancelEditing()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Theme.Hangs.Colors.pink)
                            .padding(8)
                            .background(
                                Circle().fill(Theme.Hangs.Colors.pinkSoft)
                            )
                    }
                    .accessibilityLabel(String(localized: "Cancel editing", comment: "Accessibility label for the cancel-editing button on the answer confirmation sheet"))
                    .accessibilityIdentifier("confirmation.editCancel")
                } else {
                    Button {
                        beginEditing()
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Theme.Hangs.Colors.pink)
                            .padding(8)
                            .background(
                                Circle().fill(Theme.Hangs.Colors.pinkSoft)
                            )
                    }
                    .accessibilityLabel(String(localized: "Edit answer", comment: "Accessibility label for the edit-answer button on the answer confirmation sheet"))
                    .accessibilityIdentifier("confirmation.edit")
                }
            }
            .padding(.bottom, 14)

            if let matchedOption, !isEditing {
                Text(verbatim: matchedOption)
                    .font(.hangsMono(12, weight: .medium))
                    .tracking(1.5)
                    .foregroundColor(Theme.Hangs.Colors.blue)
                    .accessibilityIdentifier("confirmation.matchedOption")
                    .padding(.bottom, 10)
            }

            ScrollView(.vertical, showsIndicators: false) {
                if isEditing {
                    editableTranscript
                } else if isEmptyAnswer {
                    // #171 Track B: nothing was captured. An empty pink rule with
                    // no words reads as a rendering bug, so name the state; the
                    // muted tone marks it as the app's report, not the driver's
                    // words. Confirm here submits "no answer".
                    HangsQuestionPrompt(
                        text: String(localized: "Nothing heard", comment: "Answer confirmation sheet: shown in place of the transcript when the recording produced no text"),
                        barColor: Theme.Hangs.Colors.pink,
                        textFont: .hangsDisplay(32, weight: .black),
                        textColor: Theme.Hangs.Colors.muted,
                        minimumScaleFactor: 0.6
                    )
                    .accessibilityIdentifier("confirmation.noAnswer")
                } else {
                    HangsQuestionPrompt(
                        text: transcribedAnswer,
                        barColor: Theme.Hangs.Colors.pink,
                        textFont: .hangsDisplay(32, weight: .black),
                        textColor: Theme.Hangs.Colors.ink,
                        minimumScaleFactor: 0.6
                    )
                    .accessibilityLabel(String(localized: "Your transcribed answer: \(transcribedAnswer)", comment: "Accessibility label reading back the user's transcribed answer"))
                    .accessibilityIdentifier("confirmation.answer")
                }
            }
            .frame(maxHeight: .infinity)

            // #131 Track F: full ListenBar — confirmation is a quiz screen, and
            // its three commands need the words on their own line.
            if let commandHint, !isEditing {
                ListenBar(mode: .command, feedback: commandFeedback, commandHint: commandHint)
                    .padding(.top, 12)
                    .transition(.opacity)
            }

            HStack(spacing: 10) {
                HangsSecondaryButton(title: "Re-record", icon: "mic.fill", height: 54) {
                    editFocused = false
                    onReRecord()
                }
                .accessibilityIdentifier("confirmation.reRecord")
                .disabled(autoConfirmEnabled && autoConfirmCountdown == 0 && !isEditing)
                .opacity(autoConfirmEnabled && autoConfirmCountdown == 0 && !isEditing ? 0.45 : 1)

                // #108B: countdown lives inside the CTA (Waze-like drain + "Ns"
                // chip, pen `R5JfD`) — replaces the old separate countdown bar.
                HangsPrimaryButton(
                    title: "Confirm",
                    icon: "checkmark",
                    height: 54,
                    countdownSecondsRemaining: autoConfirmEnabled && !isEditing && autoConfirmCountdown > 0
                        ? autoConfirmCountdown : nil,
                    countdownTotal: autoConfirmTotal
                ) {
                    editFocused = false
                    onConfirm()
                }
                // #171 Track B: an empty field stays confirmable — it now MEANS
                // "no answer" and submits as such. Disabling it was what left an
                // empty recording with no way off the sheet but a re-record.
                .accessibilityLabel(isEmptyAnswer
                    ? String(localized: "Confirm without an answer", comment: "Accessibility label for the confirm button when the answer field is empty, which submits no answer")
                    : autoConfirmEnabled && autoConfirmCountdown > 0 && !isEditing
                    ? String(localized: "Confirm answer, auto-confirming in \(autoConfirmCountdown) seconds", comment: "Accessibility label for the confirm button while auto-confirm counts down")
                    : String(localized: "Confirm answer", comment: "Accessibility label for the confirm-answer button"))
                .accessibilityIdentifier("confirmation.confirm")
            }
            .padding(.top, 14)

            // #171 Track D: secondary to Confirm on purpose — pausing is the
            // rarer intent, and the CTA row must not lose its two-thumb layout.
            // Hidden while editing: the keyboard already suspended the
            // countdown, and a Pause pill under an open keyboard is noise.
            if let onTogglePause, !isEditing {
                HangsSecondaryButton(
                    title: isPaused ? "Continue" : "Pause",
                    icon: isPaused ? "play.fill" : "pause.fill",
                    height: 48
                ) {
                    editFocused = false
                    onTogglePause()
                }
                .accessibilityIdentifier("confirmation.pause")
                .padding(.top, 10)
            }
        }
    }

    /// The field holds nothing to submit — either the recording captured no
    /// text (#171 Track B) or the driver cleared it while editing.
    private var isEmptyAnswer: Bool {
        transcribedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var editableTranscript: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Theme.Hangs.Colors.pink)
                .frame(width: 3)
                .frame(maxHeight: .infinity, alignment: .top)
            TextField("", text: $transcribedAnswer, axis: .vertical)
                .font(.hangsDisplay(32, weight: .black))
                .tracking(-1)
                .foregroundColor(Theme.Hangs.Colors.ink)
                .tint(Theme.Hangs.Colors.pink)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .focused($editFocused)
                .submitLabel(.done)
                .onSubmit { editFocused = false }
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { editFocused = false }
                            .font(.hangsBody(15, weight: .semibold))
                            .foregroundColor(Theme.Hangs.Colors.pink)
                    }
                }
                .accessibilityIdentifier("confirmation.answerField")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func beginEditing() {
        onEditingBegan?()
        isEditing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            editFocused = true
        }
    }

    private func cancelEditing() {
        editFocused = false
        isEditing = false
        onCancelEditing?()
    }

    // MARK: - Processing state

    private var processingBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            HangsSectionLabel(text: "PROCESSING", color: Theme.Hangs.Colors.blue)

            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Theme.Hangs.Colors.blue)
                    .frame(width: 3, height: 56)
                HStack(spacing: 14) {
                    ProgressView()
                        .scaleEffect(1.2)
                        .tint(Theme.Hangs.Colors.pink)
                        .accessibilityHidden(true)
                    Text("Transcribing…")
                        .font(.hangsDisplay(28, weight: .black))
                        .tracking(-1)
                        .foregroundColor(Theme.Hangs.Colors.ink)
                }
                .accessibilityLabel(String(localized: "Processing your answer", comment: "Accessibility label for the processing state on the answer confirmation sheet"))
            }

            Spacer(minLength: 0)

            if let onCancel {
                HangsSecondaryButton(title: "Cancel", icon: "xmark", height: 54) {
                    onCancel()
                }
                .accessibilityLabel(String(localized: "Cancel processing", comment: "Accessibility label for the cancel-processing button"))
                .accessibilityIdentifier("confirmation.cancel")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

#if DEBUG
    #Preview("Transcript") {
        AnswerConfirmationView(
            isProcessing: false,
            transcribedAnswer: .constant("Z mumíí."),
            autoConfirmCountdown: 4,
            autoConfirmEnabled: true,
            autoConfirmTotal: 5,
            onConfirm: {},
            onReRecord: {}
        )
    }

    #Preview("Nothing heard") {
        AnswerConfirmationView(
            isProcessing: false,
            transcribedAnswer: .constant(""),
            autoConfirmCountdown: 3,
            autoConfirmEnabled: true,
            autoConfirmTotal: 5,
            onConfirm: {},
            onReRecord: {}
        )
    }

    #Preview("MCQ voice match") {
        AnswerConfirmationView(
            isProcessing: false,
            transcribedAnswer: .constant("Kocka"),
            autoConfirmCountdown: 4,
            autoConfirmEnabled: true,
            autoConfirmTotal: 5,
            onConfirm: {},
            onReRecord: {},
            matchedOption: "A · Kocka"
        )
    }

    #Preview("Transcript long") {
        AnswerConfirmationView(
            isProcessing: false,
            transcribedAnswer: .constant("The capital of France is Paris and it has been so since the 10th century."),
            autoConfirmCountdown: 3,
            autoConfirmEnabled: true,
            autoConfirmTotal: 5,
            onConfirm: {},
            onReRecord: {}
        )
    }

    #Preview("Paused") {
        AnswerConfirmationView(
            isProcessing: false,
            transcribedAnswer: .constant("Z mumíí."),
            autoConfirmCountdown: 0,
            autoConfirmEnabled: true,
            autoConfirmTotal: 5,
            onConfirm: {},
            onReRecord: {},
            isPaused: true,
            onTogglePause: {}
        )
    }

    #Preview("Processing") {
        AnswerConfirmationView(
            isProcessing: true,
            transcribedAnswer: .constant(""),
            autoConfirmCountdown: 0,
            autoConfirmEnabled: true,
            autoConfirmTotal: 5,
            onConfirm: {},
            onReRecord: {},
            onCancel: {}
        )
    }
#endif
