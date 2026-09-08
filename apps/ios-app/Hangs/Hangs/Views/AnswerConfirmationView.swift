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
    /// #171 Track D: the quiz is paused — the countdown is gone (the presenter
    /// zeroes it), the listener is down, and the header says so. Pausing itself
    /// moved to the quiz toolbar in #173, so this sheet only REPORTS the state.
    var isPaused: Bool = false
    /// #173 C2: non-nil while the confirmed answer is being graded. The sheet
    /// stays up instead of handing the screen to a full-screen overlay: the
    /// primary button becomes the spinner and every other control goes dead.
    /// It carries the submitted text because `confirmAnswer()` consumes
    /// `transcribedAnswer` the moment it is called.
    var evaluatingAnswer: String? = nil

    @State private var isEditing = false
    @FocusState private var editFocused: Bool

    /// The answer is out of the driver's hands — nothing on the sheet may move it.
    private var isEvaluating: Bool { evaluatingAnswer != nil }

    /// What the transcript block shows: the submitted text while evaluating,
    /// the live field otherwise.
    private var displayedAnswer: String { evaluatingAnswer ?? transcribedAnswer }

    var body: some View {
        ZStack {
            Theme.Hangs.Colors.bg.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                // #173 C2: EVALUATING WINS. `confirmAnswer()` consumes the
                // transcript synchronously, so the presenter's "a transcript is
                // still in flight" test (`.processing` + empty field) is also
                // true for the whole evaluating window — and the transcribing
                // spinner would hide the very button the state now lives in,
                // while offering a Cancel that drops the answer mid-grade.
                // Deciding it HERE, not at the call site, is what stops the two
                // states from ever disagreeing again.
                if isProcessing, !isEvaluating {
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
        // #173 decision 4: pause moved to the quiz toolbar, and this sheet is
        // reachable IN a paused state (pausing mid-recording lands here) — so the
        // toolbar behind it must stay tappable or pause would be one-way. Only
        // the half-screen the sheet does not cover becomes interactive; the quiz
        // controls down there refuse to act in `.processing` anyway.
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        // Still no swipe-to-dismiss: the sheet is left by an answer decision,
        // never by a stray drag.
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
                    .disabled(isEvaluating)
                    .opacity(isEvaluating ? 0.45 : 1)
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
                        text: displayedAnswer,
                        barColor: Theme.Hangs.Colors.pink,
                        textFont: .hangsDisplay(32, weight: .black),
                        textColor: Theme.Hangs.Colors.ink,
                        minimumScaleFactor: 0.6
                    )
                    .accessibilityLabel(String(localized: "Your transcribed answer: \(displayedAnswer)", comment: "Accessibility label reading back the user's transcribed answer"))
                    .accessibilityIdentifier("confirmation.answer")
                }
            }
            .frame(maxHeight: .infinity)

            // #131 Track F: full ListenBar — confirmation is a quiz screen, and
            // its three commands need the words on their own line.
            if let commandHint, !isEditing, !isEvaluating {
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
                .disabled(isReRecordLocked || isEvaluating)
                // C2: 45 % is the mock's "this is not yours right now" tone.
                .opacity(isReRecordLocked || isEvaluating ? 0.45 : 1)

                // #108B: countdown lives inside the CTA (Waze-like drain + "Ns"
                // chip, pen `R5JfD`) — replaces the old separate countdown bar.
                HangsPrimaryButton(
                    // #173 C2: the evaluating state IS the button. Same key the
                    // retired full-screen overlay used, so SK/CS need nothing new.
                    title: isEvaluating ? "Evaluating…" : "Confirm",
                    icon: isEvaluating ? nil : "checkmark",
                    isLoading: isEvaluating,
                    height: 54,
                    countdownSecondsRemaining: autoConfirmEnabled && !isEditing && !isEvaluating && autoConfirmCountdown > 0
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

            // #173 decision 4: the Pause/Continue pill is GONE from this sheet —
            // pause is a toolbar control now, reachable in every quiz state
            // instead of only the one screen that happened to host it.
        }
    }

    /// Re-record is locked only while the auto-confirm window has actually
    /// RUN OUT — the submit is firing, and a second recording would race it.
    /// A countdown of 0 also means "paused" (#171 Track D cancels it), and
    /// there nothing is in flight: pause exists so the driver can take their
    /// time, and re-recording is one of the things they take it for. Locking
    /// it there would leave a paused sheet with Confirm as its only exit.
    private var isReRecordLocked: Bool {
        autoConfirmEnabled && autoConfirmCountdown == 0 && !isEditing && !isPaused
    }

    /// The field holds nothing to submit — either the recording captured no
    /// text (#171 Track B) or the driver cleared it while editing.
    private var isEmptyAnswer: Bool {
        displayedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            isPaused: true
        )
    }

    #Preview("Evaluating") {
        AnswerConfirmationView(
            isProcessing: false,
            transcribedAnswer: .constant(""),
            autoConfirmCountdown: 0,
            autoConfirmEnabled: true,
            autoConfirmTotal: 5,
            onConfirm: {},
            onReRecord: {},
            evaluatingAnswer: "A · Textured wallpaper"
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
