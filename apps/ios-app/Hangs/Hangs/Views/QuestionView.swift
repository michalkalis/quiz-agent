//
//  QuestionView.swift
//  Hangs
//
//  QuestionView redesigned to match Pencil frames b8zObz (MCQ), WCaT6 (TrueFalse),
//  f9csl (Listen/ready), uGhZg (Capture/recording) — issue #52 task 52.10.
//  #83 (G1 unified quiz chrome): both modes share the same top bar (close + settings
//  + progress bar), a muted category + counter meta row above the question, and the
//  think/answer timer strip at the BOTTOM next to the action row.
//  MCQ (#125 Variant A): 2×2 AnswerTile grid, docked answer ListenBar, Skip.
//       Voice: display-font question, Record/Stop | Skip action row.
//

import Combine
import SwiftUI

struct QuestionView: View {
    @ObservedObject var viewModel: QuizViewModel
    /// #155 TestFlight-only rating affordance; nil (the default) = no chip.
    var ratingEntry: QuestionRatingEntry?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showEndQuizConfirmation = false
    @State private var showQuizSettings = false
    /// #173: the ⋯ menu's "Rate question" row presents the #155 panel from here
    /// now that the floating chip is gone (it collided with the MCQ category —
    /// the founder's 2026-09-07 report).
    @State private var ratingPresentation: QuestionRatingPresentation?
    /// #173 B1: the ListenBar the driver hid with the ✕. Per question on
    /// purpose — the next question arms its own bar (see `ListenBarDismissal`).
    @State private var listenBarDismissal = ListenBarDismissal()
    @State private var showTextInput = false
    @State private var textAnswer = ""
    /// #125: true while more of the stem sits below the fold — drives the
    /// bottom fade + "SCROLL ↓" overflow cue on the MCQ stem.
    @State private var showScrollCue = false
    /// TF build 53 feedback: a long stem auto-scrolls to its end after a short
    /// beat, so a driver reads the whole question hands-free. One position +
    /// overflow pair serves both stem ScrollViews — MCQ and voice are exclusive
    /// branches, never on screen together.
    @State private var stemScroll = ScrollPosition()
    @State private var stemOverflow: CGFloat = 0
    @FocusState private var isTextFieldFocused: Bool
    /// #171 Track E: the answer just submitted for THIS question, echoed by the
    /// evaluating overlay. Written at each submit site the screen owns (tapped MCQ
    /// option, confirmed voice transcript, typed answer) and cleared when the next
    /// question arrives, so a skip can never inherit the previous answer's echo.
    @State private var submittedAnswer = ""

    /// #171 Track I: "A · Kocka" for the confirmation sheet when a spoken answer
    /// resolved to an MCQ option. Derived from the same `mcqVoiceMatchedKey` the
    /// option grid highlights, so the sheet can never disagree with the grid.
    private var matchedVoiceOptionLabel: String? {
        guard let key = viewModel.mcqVoiceMatchedKey,
              let value = viewModel.currentQuestion?.possibleAnswers?[key]
        else { return nil }
        return "\(key.uppercased()) · \(value)"
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.Hangs.Colors.bg.ignoresSafeArea()

            // #122 Variant C: ambient bottom-third wash — teal on a matched
            // command, one amber breath on a content-bearing miss. Behind all
            // content, hit-testing disabled inside the component.
            AmbientGlowWash(phase: viewModel.voiceFeedbackPhase)
                .frame(height: 330)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea()

            // #125: measure the container height once — SE-class (≤ 700pt tall)
            // degrades the stem floor / type / tile / bar sizes off the height,
            // not the device model.
            GeometryReader { geo in
                let compact = geo.size.height <= 700
                VStack(spacing: 0) {
                    topChrome(question: viewModel.currentQuestion)

                    if let question = viewModel.currentQuestion {
                        if question.isMultipleChoice {
                            mcqBody(question: question, compact: compact)
                        } else {
                            voiceBody(question: question, compact: compact)
                        }
                    } else {
                        Spacer()
                        ProgressView().tint(Theme.Hangs.Colors.pink)
                        Spacer()
                    }
                }
            }

            // #174 A1: the confirmation sheet keeps `presentationBackgroundInteraction`
            // so the toolbar's pause stays reachable (#173 decision 4) — and that
            // is exactly what switches the system's dimming OFF, which is why the
            // sheet read as more screen rather than a layer over one. Dim the quiz
            // ourselves and pass every touch straight through, so the toolbar
            // underneath keeps working.
            if isConfirmationPresented {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("question.sheetDim")
            }
        }
        // The echo belongs to one question only.
        .onChange(of: viewModel.currentQuestion?.id) { _, _ in
            submittedAnswer = ""
        }
        // The voice paths (confirm sheet, auto-confirm, an edited transcript) all
        // land the final text in `transcribedAnswer` before submitting, and it is
        // cleared on submit — so the last non-empty value IS what was sent.
        // `.task(id:)` rather than `.onChange`: it also runs on the first frame,
        // which is what a screen entered with a transcript already set needs.
        .task(id: viewModel.transcribedAnswer) {
            if !viewModel.transcribedAnswer.isEmpty {
                submittedAnswer = viewModel.transcribedAnswer
            }
        }
        // #173 decision 1: ONE header for every question type, and it is the
        // native toolbar — the two hand-rolled top rows had drifted apart and
        // the TestFlight chips were an absolutely positioned overlay that
        // collided with the MCQ category label at a fixed inset.
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar { quizToolbar }
        // #155 (TestFlight/Debug only): rate the question. Rating-only — it
        // never reads an answer or moves the quiz state machine.
        .sheet(item: $ratingPresentation) { presentation in
            QuestionRatingSheet(viewModel: presentation.viewModel)
        }
        .sensoryFeedback(.start, trigger: viewModel.quizState == .recording)
        .interactiveMinimize(
            isMinimized: $viewModel.isMinimized,
            canMinimize: viewModel.canMinimize
        )
        // #173 C2: the sheet OUTLIVES the confirm tap — it stays up, showing the
        // evaluating state in its own primary button, until the result lands.
        .sheet(isPresented: confirmationSheetBinding, onDismiss: {
            viewModel.handleAnswerConfirmationDismissed()
        }) {
            AnswerConfirmationView(
                // `!isEditingTranscript`: deleting the whole prefill while editing
                // must not flip the sheet into the Transcribing spinner — the
                // "dialog vanished" bug from TF build 53 feedback.
                // `!noAnswerCaptured` (#171 Track B): the no-answer sheet is also
                // `.processing` with an empty field, but nothing is in flight —
                // showing the spinner there would hide the Confirm CTA that ends
                // the question.
                isProcessing: viewModel.quizState == .processing && viewModel.transcribedAnswer.isEmpty
                    && !viewModel.isEditingTranscript && !viewModel.noAnswerCaptured,
                transcribedAnswer: $viewModel.transcribedAnswer,
                autoConfirmCountdown: viewModel.autoConfirmCountdown,
                autoConfirmEnabled: viewModel.settings.autoConfirmEnabled,
                autoConfirmTotal: Config.autoConfirmDelaySecs,
                onConfirm: { Task { await viewModel.confirmAnswer() } },
                onReRecord: { viewModel.rerecordAnswer() },
                onEditingBegan: { viewModel.beginEditingTranscript() },
                onCancelEditing: { viewModel.cancelEditingTranscript() },
                onCancel: { viewModel.cancelProcessing() },
                isListeningForCommands: viewModel.commandListenerHint != nil,
                commandHint: viewModel.voiceHintWords,
                showsVoiceGlyph: viewModel.showsVoiceGlyph,
                commandLanguage: viewModel.commandLanguage,
                commandFeedback: viewModel.voiceFeedbackPhase,
                matchedOption: matchedVoiceOptionLabel,
                isPaused: viewModel.isPaused,
                evaluatingAnswer: viewModel.isEvaluatingAnswer ? submittedAnswer : nil
            )
        }
        .sheet(isPresented: $showQuizSettings) {
            // #68 resolution: the chip opens the full settings screen, which now
            // contains the Session group (decision 6 Variant A rows). The #86
            // Pencil pass approved the session card on the Settings screen only —
            // no separate in-quiz menu frame exists.
            SettingsView(viewModel: viewModel)
        }
        // #81 / frame w9tOoU: native alert, Continue (cancel) + destructive End Quiz,
        // title only — replaces the bottom confirmationDialog.
        .alert("End Quiz?", isPresented: $showEndQuizConfirmation) {
            Button("Continue", role: .cancel) {}
            // #125: the MCQ screen drops its settings gear, so settings stay
            // reachable through this sheet (both modes share the alert).
            Button("Settings") { showQuizSettings = true }
            // Founder 2026-08-03 (Sporcle-style early exit): ending mid-quiz can
            // land on the score screen for the questions answered so far instead
            // of discarding the run.
            Button("End & See Results") {
                Task { await viewModel.endQuizWithResults() }
            }
            Button("End Quiz", role: .destructive) {
                Task { await viewModel.endQuiz() }
            }
        }
        // #81 follow-up (founder 2026-07-06): the think/answer countdowns keep
        // running behind the dialog and the settings sheet — a pause here would
        // let the user buy thinking time by opening a modal (same rationale as
        // the no-pause-while-typing decision 2a).
    }

    // MARK: - Toolbar (#173 decision 1, variant A3)

    /// One toolbar for MCQ, voice and image questions, in every quiz state.
    /// ✕ leading; the two mid-question controls (mute, pause) grouped trailing;
    /// everything else under ⋯ — the HIG "More" rule, and the reason nothing can
    /// overlap the category label any more.
    @ToolbarContentBuilder
    private var quizToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { showEndQuizConfirmation = true } label: {
                Image(systemName: "xmark")
            }
            .tint(Theme.Hangs.Colors.ink)
            .accessibilityLabel(Text("Close quiz"))
            .accessibilityIdentifier("question.closeButton")
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            // #173 Track A: the toolbar mute is quiz-scoped — it must show the
            // EFFECTIVE mute, not the persisted Settings preference.
            QuizMuteToolbarButton(isMuted: viewModel.isAudioMuted) {
                Task { await viewModel.toggleMute() }
            }
            QuizPauseToolbarButton(isPaused: viewModel.isPaused, showsVoiceGlyph: viewModel.showsVoiceGlyph) {
                viewModel.togglePause()
            }
            .disabled(!viewModel.canPauseQuiz && !viewModel.isPaused)
        }

        // Separates the live controls from the menu, so the ⋯ never reads as a
        // third mid-question button.
        ToolbarSpacer(.fixed, placement: .topBarTrailing)

        ToolbarItem(placement: .topBarTrailing) {
            QuizOverflowMenu(
                onSettings: { showQuizSettings = true },
                onFeedback: ratingEntry?.isEnabled == true ? ratingEntry?.openFeedback : nil,
                onRateQuestion: rateQuestionAction
            )
        }
    }

    /// The #155 gate, unchanged: TestFlight/Debug only, and only with a question
    /// to rate. nil = the row is absent, which is what an App Store build gets.
    private var rateQuestionAction: (() -> Void)? {
        guard let ratingEntry, ratingEntry.isEnabled,
              let questionId = viewModel.currentQuestion?.id
        else { return nil }
        let questionText = viewModel.currentQuestion?.question
        return {
            ratingPresentation = QuestionRatingPresentation(
                viewModel: ratingEntry.makeViewModel(questionId, questionText)
            )
        }
    }

    /// #173 C2: `confirmAnswer()` clears `showAnswerConfirmation` synchronously —
    /// that flag is its single-flight token and must keep doing that. The sheet's
    /// PRESENTATION outlives it by one extra flag, so the driver keeps looking at
    /// the button they pressed while the answer is graded.
    private var confirmationSheetBinding: Binding<Bool> {
        Binding(
            get: { isConfirmationPresented },
            set: { if !$0 { viewModel.showAnswerConfirmation = false } }
        )
    }

    /// The sheet is on screen — one predicate for both its presentation and the
    /// #174 A1 dim, so the quiz can never be dimmed without the sheet or vice versa.
    private var isConfirmationPresented: Bool {
        viewModel.showAnswerConfirmation || viewModel.isEvaluatingAnswer
    }

    // MARK: - Top chrome (#173 variant A3)

    /// Under the toolbar: segmented 1-based progress over one small mono meta
    /// row. Replaces BOTH the merged MCQ row and the voice `metaRow` — one
    /// header, every question type.
    private func topChrome(question: Question?) -> some View {
        VStack(spacing: 8) {
            HangsQuizProgressHeader(
                category: question.map { Config.categoryDisplayName(for: $0.category) } ?? "",
                current: currentQuestionNumber,
                total: totalQuestions,
                // #122: the fill flips teal for the duration of a matched glow.
                tint: viewModel.voiceFeedbackPhase == .matched
                    ? Theme.Hangs.Colors.accentTeal : nil,
                isRecording: isRecording
            )
            .padding(.top, 8)

            if let error = viewModel.errorMessage {
                errorBanner(error)
            }
        }
    }

    private var totalQuestions: Int {
        viewModel.currentSession?.maxQuestions ?? viewModel.settings.numberOfQuestions
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

    // MARK: - Tap-to-replay question block

    /// Tap-anywhere-on-question replay (founder, 2026-07-11 — replaces the audio
    /// strip's replay link, #85 Variant B): the whole question block is the replay
    /// control. It calls the timer-free `replayQuestionAudio()` (Decision 2) — never
    /// re-arms the think/answer countdown, and a tap during playback restarts the
    /// question TTS from the top. Disabled when there's nothing to replay (muted or
    /// no question audio URL, #59.5); the question must stay fully readable, so only
    /// the speaker glyph fades, never the text.
    private func questionReplayTapTarget(@ViewBuilder content: () -> some View) -> some View {
        Button {
            Task { await viewModel.replayQuestionAudio() }
        } label: {
            content()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canReplayAudio)
        .accessibilityHint("Replays the question")
        .accessibilityIdentifier("question.replay")
    }

    /// Discoverability affordance for the tappable question block: a small muted
    /// glyph under the question, fading when replay is unavailable.
    ///
    /// #173 finding 6: `arrow.counterclockwise` — Apple's restart/reload symbol,
    /// which is what a replay IS. The old `speaker.wave.2.fill` collided with the
    /// mute toggle (same speaker family, opposite meaning), and `repeat` reads as
    /// loop mode. The MCQ stem gets the SAME glyph now: it was dropped there "for
    /// space", which left the driver with no sign the stem was tappable at all.
    private var replayGlyph: some View {
        Image(systemName: "arrow.counterclockwise")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(Theme.Hangs.Colors.muted)
            .opacity(viewModel.canReplayAudio ? 1 : 0.4)
            .accessibilityHidden(true)
            .accessibilityIdentifier("question.replayGlyph")
    }

    // MARK: - MCQ body (#125 Variant A "Answer Grid")

    /// The #125 answer-reveal gate is GONE (founder reversed the 2026-07-28
    /// hide-until-the-timer decision on 2026-07-29, #132): on MCQ the driver must
    /// see the options while thinking, so the grid renders from the first frame.
    /// The answer `ListenBar` is NOT part of that reversal — it still claims the
    /// mic is live, so it stays gated on `.recording`.
    private func mcqBody(question: Question, compact: Bool) -> some View {
        VStack(spacing: 0) {
            // Merged top row (close + category + counter) lives in `topChrome`
            // now; the MCQ body starts at the stem.
            mcqStem(question: question, compact: compact)

            // #173 B1 (founder pick): the listening banner sits ABOVE the option
            // grid, directly under the stem — where the eye already is when the
            // countdown starts. Below the grid it was reliably missed (the
            // 2026-09-07 report), and it is the one element that tells the driver
            // the mic is about to open.
            mcqListenBar(question: question, compact: compact)

            MCQOptionPicker(
                options: question.sortedAnswerOptions,
                onSelect: { key, value in
                    submittedAnswer = value
                    Task { await viewModel.submitMCQAnswer(key: key, value: value) }
                },
                externalSelectedKey: $viewModel.mcqVoiceMatchedKey,
                compact: compact,
                // #174: a tapped option evaluates IN the tile it was tapped on.
                isSubmitting: isProcessing
            )
            .padding(.top, compact ? 10 : 14)

            // #122: light sweep strip — always reserves its 4 pt so the docked bar
            // below never shifts; glows only during a feedback phase.
            GlowSweepLine(phase: viewModel.voiceFeedbackPhase)
                .padding(.horizontal, 20)
                .padding(.top, 8)

            // Founder 2026-08-03: skip is a secondary escape hatch, not the
            // screen's CTA — a compact centered chip (voice footer's skip
            // styling), no longer a full-width bar competing with the options.
            // #174: it STAYS on screen while evaluating (disabled) — the chip is
            // where a skip in flight shows its own spinner now.
            mcqSkipChip
                .padding(.top, compact ? 8 : 12)
                .padding(.bottom, compact ? 10 : 16)

            #if DEBUG
                Text(quizStateName)
                    .frame(width: 0, height: 0)
                    .accessibilityIdentifier("question.state")
            #endif
        }
        .frame(maxHeight: .infinity)
    }

    /// #132 Track B (variant A "odpočet v lište"): ONE bar slot from the first
    /// countdown tick to submit. While the driver decides it shows the think
    /// state — teal drain + seconds + the command words; the moment the mic goes
    /// live it flips to the pink answer state. Silent while the question is
    /// still being read, and while an answer is being evaluated.
    ///
    /// #173 B1: it now carries a ✕. Dismissal is scoped to the question on
    /// screen (`ListenBarDismissal`) — nothing is persisted, so the
    /// next question arms its own bar and a driver cannot permanently lose the
    /// only surface that names the voice commands.
    @ViewBuilder
    private func mcqListenBar(question: Question, compact: Bool) -> some View {
        if isProcessing || listenBarDismissal.isHidden(questionId: question.id) {
            EmptyView()
        } else if isRecording {
            ListenBar(
                mode: .answer(question.sortedAnswerOptions.count == 2 ? .trueFalse : .mcq),
                feedback: viewModel.voiceFeedbackPhase,
                // #131 Track F folded the old SE-class `compact` flag into the
                // one size axis: a short container gets the slim bar.
                size: compact ? .slim : .full,
                onDismiss: { listenBarDismissal.dismiss(questionId: question.id) }
            )
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .transition(.opacity)
        } else if viewModel.answerWindowRemaining > 0 {
            ListenBar(
                mode: .command,
                feedback: viewModel.voiceFeedbackPhase,
                commandHint: viewModel.voiceHintWords,
                size: compact ? .slim : .full,
                language: viewModel.commandLanguage,
                thinkCountdown: .init(remaining: viewModel.answerWindowRemaining,
                                      total: viewModel.answerWindowTotal),
                onDismiss: { listenBarDismissal.dismiss(questionId: question.id) }
            )
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .transition(.opacity)
        }
    }

    /// Compact MCQ skip chip — mirrors the voice footer's skip styling so the
    /// two modes read the same. Disabled while an answer is being evaluated.
    private var mcqSkipChip: some View {
        Button {
            Task { await viewModel.skipQuestion() }
        } label: {
            HStack(spacing: 6) {
                // #174: a skip in flight spins IN this chip. The label is
                // unchanged so the capsule keeps its width.
                if isSkipping {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.Hangs.Colors.ink)
                        .accessibilityIdentifier("question.processingIndicator")
                } else {
                    // Founder pick (#171, 2026-09-06): two chevrons read as "skip";
                    // the play+bar glyph read as media transport.
                    Image(systemName: "chevron.right.2")
                        .font(.system(size: 12, weight: .semibold))
                }
                Text("Skip question")
                    .font(.hangsBody(15, weight: .medium))
            }
            .foregroundColor(Theme.Hangs.Colors.ink)
            .frame(height: 40)
            .padding(.horizontal, 16)
            .background(Capsule().fill(Theme.Hangs.Colors.bgCard))
            .overlay(Capsule().stroke(Theme.Hangs.Colors.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(isProcessing)
        // Busy is not unavailable: the skipping chip keeps full contrast so its
        // spinner reads, while a chip disabled by an answer in flight dims.
        .opacity(isProcessing && !isSkipping ? 0.45 : 1)
        .accessibilityIdentifier("question.skip")
    }

    // MARK: - TEMP provenance badge (Bedrock gen test)

    /// TEMP (Bedrock gen test): small caption naming the LLM that generated the
    /// question (`generated_by` from the API, e.g. "bedrock:us.mistral…").
    /// Remove before App Store release.
    @ViewBuilder
    private func generatedByBadge(_ question: Question, horizontalPadding: CGFloat) -> some View {
        if let generatedBy = question.generatedBy {
            Text(generatedBy)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.Hangs.Colors.ink.opacity(0.45))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, horizontalPadding)
                .accessibilityHidden(true)
        }
    }

    // MARK: - MCQ stem (floor + overflow affordance — #125 Variant A)

    /// The stem scroll region: a hard floor (360pt, 300 on SE-class) at Anton 34
    /// (30 on SE); anything past the floor scrolls behind a VISIBLE overflow
    /// affordance — a bottom fade, a "SCROLL ↓" cue, and the native indicator — so
    /// a long stem reads as scrollable, never clipped. The `GeometryReader` +
    /// `minHeight` keeps the flexible ScrollView from being squeezed to near-zero
    /// by the fixed-height grid below (54.2's failure mode).
    private func mcqStem(question: Question, compact: Bool) -> some View {
        let floor: CGFloat = compact ? 300 : 360
        let stemFont: Font = .hangsDisplay(compact ? 30 : 34)
        return GeometryReader { geo in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    questionReplayTapTarget {
                        // #173 finding 6: the replay glyph is BACK on MCQ. #132
                        // dropped it for vertical space, and the founder read the
                        // stem as untappable — a 12pt glyph is a cheaper price
                        // than an undiscoverable replay.
                        VStack(alignment: .leading, spacing: 8) {
                            HangsQuestionPrompt(
                                text: question.question,
                                barColor: Theme.Hangs.Colors.blue,
                                textFont: stemFont,
                                textIdentifier: "question.text"
                            )
                            // Keep the stem its OWN a11y element inside the
                            // replay button. A button label that resolves to a
                            // single element gets folded into the button, taking
                            // the stem's identifier with it.
                            .accessibilityElement(children: .contain)
                            replayGlyph
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // TEMP (Bedrock gen test): provenance badge showing which
                    // LLM generated the question — remove before App Store release.
                    generatedByBadge(question, horizontalPadding: 28)
                }
                .frame(minHeight: geo.size.height, alignment: .top)
            }
            .scrollIndicators(.visible)
            .scrollPosition($stemScroll)
            .onScrollGeometryChange(for: Bool.self) { g in
                // Is there more stem below the fold? (taller than the viewport
                // AND not scrolled to the end.)
                g.contentOffset.y + g.containerSize.height < g.contentSize.height - 1
            } action: { _, more in
                showScrollCue = more
            }
            .onScrollGeometryChange(for: CGFloat.self) { g in
                max(0, g.contentSize.height - g.containerSize.height)
            } action: { _, overflow in
                stemOverflow = overflow
            }
            .task(id: question.id) {
                await autoScrollStemIfNeeded()
            }
            .overlay(alignment: .bottom) {
                if showScrollCue {
                    stemOverflowCue
                }
            }
        }
        .frame(minHeight: floor)
    }

    /// Drift a too-tall stem to its end at reading pace after a short beat
    /// (TF build 53 feedback: "the question text could auto-scroll"). A user
    /// drag interrupts the animation, so manual reading always wins.
    private func autoScrollStemIfNeeded() async {
        stemScroll.scrollTo(edge: .top)
        guard !reduceMotion else { return }
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled, stemOverflow > 0 else { return }
        withAnimation(.linear(duration: max(2, Double(stemOverflow) / 28))) {
            stemScroll.scrollTo(edge: .bottom)
        }
    }

    /// Bottom fade + a small mono "SCROLL ↓" cue — the visible overflow
    /// affordance. a11y-hidden (peripheral cue), never blocks taps.
    private var stemOverflowCue: some View {
        ZStack(alignment: .bottomTrailing) {
            LinearGradient(
                colors: [Theme.Hangs.Colors.bg.opacity(0), Theme.Hangs.Colors.bg],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 56)
            .frame(maxWidth: .infinity)

            HStack(spacing: 5) {
                Text("SCROLL")
                    .font(.hangsMono(9, weight: .medium))
                    .tracking(1.4)
                    .textCase(.uppercase)
                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(Theme.Hangs.Colors.muted)
            .padding(.trailing, 22)
            .padding(.bottom, 8)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .transition(.opacity)
    }

    // MARK: - Voice body (frames f9csl / uGhZg)

    private func voiceBody(question: Question, compact: Bool) -> some View {
        VStack(spacing: 0) {
            // #173: the category/counter row moved into the shared header under
            // the toolbar — one meta row for every question type.

            // Scroll region holds only the question, so a long Slovak question
            // can scroll without pushing the pinned controls off-screen (54.2).
            // minHeight keeps short questions top-aligned, not centered.
            GeometryReader { geo in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 16) {
                        // #68: image-type question — image above the text, scrolls
                        // with it. Text/TTS below stays the driving-mode fallback.
                        if question.hasImage {
                            ImageQuestionView(question: question)
                                .padding(.horizontal, 24)
                        }

                        // Question: Anton display, no left bar. The whole block is
                        // the tap-to-replay target (see questionReplayTapTarget).
                        questionReplayTapTarget {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(question.question)
                                    .font(.hangsDisplay(28))
                                    .foregroundColor(Theme.Hangs.Colors.ink)
                                    .minimumScaleFactor(0.7)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .accessibilityIdentifier("question.text")
                                replayGlyph
                            }
                            .padding(.horizontal, 24)
                        }
                        // TEMP (Bedrock gen test): provenance badge showing which
                        // LLM generated the question — remove before App Store release.
                        generatedByBadge(question, horizontalPadding: 24)
                    }
                    .frame(minHeight: geo.size.height, alignment: .top)
                }
                .scrollPosition($stemScroll)
                .onScrollGeometryChange(for: CGFloat.self) { g in
                    max(0, g.contentSize.height - g.containerSize.height)
                } action: { _, overflow in
                    stemOverflow = overflow
                }
                .task(id: question.id) {
                    await autoScrollStemIfNeeded()
                }
            }

            // Pinned controls below the scroll region — mute strip (G1: audio
            // controls at the bottom), then the #131 footer.
            VStack(spacing: 12) {
                // #131 Track B: the voice countdown lives in the Record/Stop
                // button. #173: the mute strip is gone — mute is a toolbar
                // control now, on one fixed spot in every state.
                // #174: the footer stays up while evaluating or skipping — its
                // own controls carry the loading state (founder: loading lives IN
                // the control that triggered it, never in an overlay).
                QuestionVoiceFooter(
                    viewModel: viewModel,
                    showTextInput: $showTextInput,
                    textAnswer: $textAnswer,
                    submittedAnswer: $submittedAnswer,
                    isTextFieldFocused: $isTextFieldFocused,
                    compact: compact
                )
            }
            // #96 P3 (founder): tighter side padding + lower footprint so the
            // action row doesn't sit needlessly high (was h24 / bottom 28).
            .padding(.bottom, 16)

            #if DEBUG
                Text(quizStateName)
                    .frame(width: 0, height: 0)
                    .accessibilityIdentifier("question.state")
            #endif
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Derived

    private var isRecording: Bool { viewModel.quizState == .recording }

    private var isSkipping: Bool { viewModel.quizState == .skipping }

    /// "Something is in flight and no sheet is covering this screen." The
    /// confirmation sheet also lives in `.processing` (every voice answer passes
    /// through it, and since #173 C2 it stays up — showing its own evaluating
    /// state — until the result lands), so the controls underneath must not read
    /// as busy while the driver is still being asked to confirm.
    private var isProcessing: Bool {
        guard !viewModel.showAnswerConfirmation, !viewModel.isEvaluatingAnswer else { return false }
        return viewModel.quizState == .processing || viewModel.quizState == .skipping
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
