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

    /// The driver TAPPED the pencil. Read `branch` / `isEditing` instead —
    /// evaluating outranks this, and this flag alone does not know that.
    @State private var editingRequested = false
    @FocusState private var editFocused: Bool

    /// The answer is out of the driver's hands — nothing on the sheet may move it.
    private var isEvaluating: Bool { evaluatingAnswer != nil }

    /// The three mutually exclusive bodies this sheet can show, and their
    /// precedence. Pure and static so the rule is assertable without driving the
    /// `@State` that feeds it.
    enum Branch: Equatable {
        /// A transcript is genuinely still in flight — spinner + Cancel.
        case transcribing
        /// The driver is fixing the transcript by hand.
        case editing
        /// The answer, read-only.
        case transcript
    }

    /// EVALUATING OUTRANKS BOTH, and this is the single place that says so.
    ///
    /// The sheet now outlives the Confirm tap (#173 C2), and `confirmAnswer()`
    /// consumes `transcribedAnswer` synchronously — which breaks the other two
    /// branches in the same way:
    ///  - the presenter's "a transcript is still in flight" test (`.processing`
    ///    + empty field) is true for the whole evaluating window, and its
    ///    spinner would hide the very button the state now lives in while
    ///    offering a Cancel that drops the answer mid-grade;
    ///  - `editingRequested` is `@State` that nothing resets, so a driver who
    ///    fixed their transcript and confirmed kept a LIVE, EMPTY `TextField`
    ///    bound to the string that was just cleared — and typing in it mutated
    ///    the answer being graded.
    static func branch(isProcessing: Bool, isEditing: Bool, isEvaluating: Bool) -> Branch {
        if isEvaluating { return .transcript }
        if isProcessing { return .transcribing }
        return isEditing ? .editing : .transcript
    }

    private var branch: Branch {
        Self.branch(isProcessing: isProcessing, isEditing: editingRequested, isEvaluating: isEvaluating)
    }

    /// The edit affordances follow the branch, never the raw flag — so the
    /// pencil's Cancel twin cannot outlive the confirm either.
    private var isEditing: Bool { branch == .editing }

    /// What the transcript block shows: the submitted text while evaluating,
    /// the live field otherwise.
    private var displayedAnswer: String { evaluatingAnswer ?? transcribedAnswer }

    /// #174 A1: the sheet is a LAYER, not more screen. One constant feeds both
    /// the presentation background and the content ground so they can never
    /// drift apart — and so the "distinct from `bg`" rule is assertable.
    static let surface = Theme.Hangs.Colors.bgSheet

    var body: some View {
        ZStack {
            Self.surface.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                // Precedence lives in `Self.branch(…)` — see it for why
                // evaluating outranks both the transcribing spinner and the
                // edit field.
                if branch == .transcribing {
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
        // A hairline where the layer starts — the top edge is the only part of
        // an undraggable sheet that can say "something is on top of the quiz".
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.Hangs.Colors.hairline)
                .frame(height: 1)
                .allowsHitTesting(false)
        }
        .presentationDetents([.medium])
        // Founder 2026-09-09: still NO grabber. The sheet cannot be dragged
        // closed, and a handle that does nothing is a lie about the affordance.
        .presentationDragIndicator(.hidden)
        .presentationBackground(Self.surface)
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

            // #174 B1: VERTICAL, and in this order. The half-width Confirm could
            // not hold "Vyhodnocujem…" (2× the length of "Potvrdiť"), so the label
            // shrank and truncated the moment the driver pressed it. Full width
            // fits every localization at full size, and nothing moves between the
            // two states because the row never re-splits.
            VStack(spacing: 8) {
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

                // Secondary in weight as well as in position: a text-style
                // control under the CTA, the standard iOS pairing.
                HangsGhostButton(
                    title: "Re-record",
                    icon: "mic.fill",
                    color: Theme.Hangs.Colors.muted,
                    font: .hangsBody(15, weight: .semibold)
                ) {
                    editFocused = false
                    onReRecord()
                }
                .frame(height: 40)
                .accessibilityIdentifier("confirmation.reRecord")
                .disabled(isReRecordLocked || isEvaluating)
                // C2: 45 % is the mock's "this is not yours right now" tone.
                .opacity(isReRecordLocked || isEvaluating ? 0.45 : 1)
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
        editingRequested = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            editFocused = true
        }
    }

    private func cancelEditing() {
        editFocused = false
        editingRequested = false
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
