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
        }
        // #155 (TestFlight/Debug only): rate the question on screen. Rating-only
        // — it never reads an answer or moves the quiz state machine.
        // The chip sits in the top row, left of what already occupies its
        // trailing edge: the settings gear in voice mode, the NN/NN counter in
        // the merged MCQ row (which it clipped at a single shared inset).
        .questionRatingEntry(
            ratingEntry,
            questionId: viewModel.currentQuestion?.id,
            questionText: viewModel.currentQuestion?.question,
            trailingInset: (viewModel.currentQuestion?.isMultipleChoice ?? false) ? 96 : 64
        )
        .sensoryFeedback(.start, trigger: viewModel.quizState == .recording)
        .interactiveMinimize(
            isMinimized: $viewModel.isMinimized,
            canMinimize: viewModel.canMinimize
        )
        .sheet(isPresented: $viewModel.showAnswerConfirmation, onDismiss: {
            viewModel.handleAnswerConfirmationDismissed()
        }) {
            AnswerConfirmationView(
                // `!isEditingTranscript`: deleting the whole prefill while editing
                // must not flip the sheet into the Transcribing spinner — the
                // "dialog vanished" bug from TF build 53 feedback.
                isProcessing: viewModel.quizState == .processing && viewModel.transcribedAnswer.isEmpty
                    && !viewModel.isEditingTranscript,
                transcribedAnswer: $viewModel.transcribedAnswer,
                autoConfirmCountdown: viewModel.autoConfirmCountdown,
                autoConfirmEnabled: viewModel.settings.autoConfirmEnabled,
                autoConfirmTotal: Config.autoConfirmDelaySecs,
                onConfirm: { Task { await viewModel.confirmAnswer() } },
                onReRecord: { viewModel.rerecordAnswer() },
                onEditingBegan: { viewModel.beginEditingTranscript() },
                onCancelEditing: { viewModel.cancelEditingTranscript() },
                onCancel: { viewModel.cancelProcessing() },
                commandHint: viewModel.commandListenerHint,
                commandFeedback: viewModel.voiceFeedbackPhase
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

    // MARK: - Top chrome

    /// The top row differs by mode (#125): voice keeps the shared close + settings
    /// bar; MCQ merges close + "CATEGORY · Qn" + counter into one row and drops the
    /// settings gear. The progress bar + error banner are shared by both.
    private func topChrome(question: Question?) -> some View {
        VStack(spacing: 8) {
            if let question, question.isMultipleChoice {
                mcqTopRow(question: question)
            } else {
                HangsQuizTopBar(
                    onClose: { showEndQuizConfirmation = true },
                    onSettings: { showQuizSettings = true }
                )
            }
            // #122: the bar flips teal for the duration of a matched glow.
            HangsProgressBar(
                progress: progressValue,
                tint: viewModel.voiceFeedbackPhase == .matched
                    ? Theme.Hangs.Colors.accentTeal : nil
            )
            if let error = viewModel.errorMessage {
                errorBanner(error)
            }
        }
    }

    // MARK: - MCQ merged top row (#125 Variant A)

    /// #125: MCQ chrome collapses to ONE row — close chip + "CATEGORY · Qn" +
    /// the NN/NN counter (keeping its pink-while-recording accent). The settings
    /// gear leaves the MCQ screen (reachable via the End Quiz sheet); the separate
    /// meta row is dropped. voiceBody keeps its own chrome + `metaRow`.
    private func mcqTopRow(question: Question) -> some View {
        HStack(spacing: 12) {
            closeChip
            // #56: interpolated literal so the compiler extracts "%@ · Q%lld";
            // uppercased as a display modifier (ViewInspector matches the source).
            Text("\(Config.categoryDisplayName(for: question.category)) · Q\(currentQuestionNumber)")
                .textCase(.uppercase)
                .font(.hangsMono(11, weight: .medium))
                .tracking(2)
                .foregroundColor(Theme.Hangs.Colors.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityIdentifier("question.category")

            Spacer(minLength: 12)

            Text(verbatim: counterString)
                .font(.hangsMono(11, weight: .semibold))
                .tracking(2)
                .foregroundColor(isRecording ? Theme.Hangs.Colors.pink : Theme.Hangs.Colors.muted)
                .accessibilityIdentifier("question.counter")
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    /// Close chip matching `HangsQuizTopBar`'s (36pt circle, xmark) — kept its
    /// `question.closeButton` id so page objects still bail out of the quiz here.
    private var closeChip: some View {
        Button { showEndQuizConfirmation = true } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.Hangs.Colors.ink)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Theme.Hangs.Colors.bgCard))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Close quiz", comment: "Accessibility label for the in-quiz close button"))
        .accessibilityIdentifier("question.closeButton")
    }

    // MARK: - Question meta row (muted category + counter)

    /// Unified muted meta row above the question in BOTH modes (#83 / G1, frames
    /// b8zObz/f9csl `metaRow`): category on the left (MCQ keeps its "· QUESTION N"
    /// suffix, voice stays lowercase — per frames), `NN / NN` counter on the right
    /// (moved here from the old nav bar). The counter turns pink while recording so
    /// the active-mic state stays glanceable now that the nav has no accent slot.
    private func metaRow(question: Question) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Group {
                if question.isMultipleChoice {
                    // #56: interpolated literal so the compiler extracts
                    // "%@ · QUESTION %lld"; uppercased as a display modifier.
                    Text("\(Config.categoryDisplayName(for: question.category)) · QUESTION \(currentQuestionNumber)")
                        .textCase(.uppercase)
                } else {
                    Text(verbatim: Config.categoryDisplayName(for: question.category).lowercased())
                }
            }
            .font(.hangsMono(11, weight: .medium))
            .tracking(2)
            .foregroundColor(Theme.Hangs.Colors.muted)
            .accessibilityIdentifier("question.category")

            Spacer(minLength: 12)

            Text(verbatim: counterString)
                .font(.hangsMono(11, weight: .semibold))
                .tracking(2)
                .foregroundColor(isRecording ? Theme.Hangs.Colors.pink : Theme.Hangs.Colors.muted)
                .accessibilityIdentifier("question.counter")
        }
    }

    private var counterString: String {
        // #79: 1-based index of the question on screen. `+1` because this renders
        // BEFORE handleQuizResponse increments questionsAnswered — so it matches
        // ResultView.counterString, which renders post-increment with no +1. Keep
        // the two in lockstep.
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

    // MARK: - Audio strip (mute — bottom, next to the action row)

    /// Fixed height reserved for the audio strip so the pinned action buttons never
    /// shift (#59.2 rationale, now at the bottom per G1/#83).
    private let audioStripHeight: CGFloat = 32

    /// G1 binding layout (#83 + #85, frames b8zObz/f9csl `audioStrip`): the mute
    /// toggle on the right. Rendered identically by both the MCQ
    /// and the voice body, through `recording` too, so the driver finds the audio
    /// controls on one fixed spot in every mode. The replay link that used to sit in
    /// the middle (#85 Variant B) became the tap-anywhere-on-question target
    /// (`questionReplayTapTarget`) — founder decision, 2026-07-11. The typed-answer
    /// link that shared the strip's middle slot moved into the footer row (#131 C).
    ///
    /// #131 Track B/C: the strip is now the MUTE's permanent home in both modes —
    /// the #125 experiment of moving mute into the docked `ListenBar` made it a
    /// duplicate of this one and cost the driver a fixed spot, so the bar dropped
    /// it and the strip renders wherever the bar can appear.
    ///
    /// #132 Track B killed the THINK/ANSWER chips: MCQ's countdown now lives in
    /// the unified `ListenBar` (variant A), just like the voice screen's lives in
    /// the Record/Stop button (#131 B). The strip keeps its id — it is still the
    /// fixed row a driver reaches for, it just only carries the mute now.
    @ViewBuilder
    private func audioStrip() -> some View {
        if viewModel.quizState == .askingQuestion || viewModel.quizState == .recording {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                muteButton
            }
            .padding(.horizontal, 24)
            .frame(minHeight: audioStripHeight)
            .accessibilityIdentifier("question.timerStrip")
        }
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
    /// speaker glyph under the question, fading when replay is unavailable.
    private var replaySpeakerGlyph: some View {
        Image(systemName: "speaker.wave.2.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(Theme.Hangs.Colors.muted)
            .opacity(viewModel.canReplayAudio ? 1 : 0.4)
            .accessibilityHidden(true)
    }

    /// On-screen mute affordance (#85 — regressed in the #52 redesign, originally #13).
    /// Routes through `toggleMute()` so muting mid-read also stops the in-flight TTS —
    /// the guards in QuizViewModel+Audio only gate *starting* playback.
    private var muteButton: some View {
        Button {
            Task { await viewModel.toggleMute() }
        } label: {
            Image(systemName: viewModel.settings.isMuted ? "speaker.slash.fill" : "speaker.wave.2")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(viewModel.settings.isMuted ? Theme.Hangs.Colors.pink : Theme.Hangs.Colors.muted)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Theme.Hangs.Colors.bgCard))
                .overlay(Circle().stroke(Theme.Hangs.Colors.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(viewModel.settings.isMuted
            ? String(localized: "Unmute", comment: "Accessibility label for the quiz mute toggle while muted")
            : String(localized: "Mute", comment: "Accessibility label for the quiz mute toggle while audible"))
        .accessibilityIdentifier("question.mute")
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

            // #131 Track C: the strip renders in BOTH phases now. #125 dropped it
            // post-reveal because the answer bar had absorbed the mute; the bar no
            // longer carries one, so removing the strip here would leave the MCQ
            // answering phase with no mute at all.
            audioStrip()
                .padding(.top, 8)

            MCQOptionPicker(
                options: question.sortedAnswerOptions,
                onSelect: { key, value in
                    Task { await viewModel.submitMCQAnswer(key: key, value: value) }
                },
                externalSelectedKey: $viewModel.mcqVoiceMatchedKey,
                compact: compact
            )
            .padding(.top, compact ? 10 : 14)

            // #122: light sweep strip — always reserves its 4 pt so the docked bar
            // below never shifts; glows only during a feedback phase.
            GlowSweepLine(phase: viewModel.voiceFeedbackPhase)
                .padding(.horizontal, 20)
                .padding(.top, 8)

            // Founder 2026-08-03: MCQ needs the same visible evaluating state
            // the voice screen has (59.6) — after tapping an option the screen
            // otherwise looks frozen until the result arrives.
            if isProcessing {
                processingRow
            }

            // #132 Track B (variant A "odpočet v lište"): ONE bar slot from the
            // first countdown tick to submit. While the driver decides, the bar
            // shows the think state — teal drain + seconds + the same command
            // words every other command bar shows (founder's correction to the
            // mock). The moment the mic goes live it flips to the pink answer
            // state (#125 addendum) — it still never claims a listening state
            // that does not exist (#132 A), because the think state doesn't
            // claim one. Silent while the question is still being read, exactly
            // like the THINK/ANSWER chips it replaces.
            if isRecording {
                ListenBar(
                    mode: .answer(question.sortedAnswerOptions.count == 2 ? .trueFalse : .mcq),
                    feedback: viewModel.voiceFeedbackPhase,
                    // #131 Track F folded the old SE-class `compact` flag into the
                    // one size axis: a short container gets the slim bar.
                    size: compact ? .slim : .full
                )
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .transition(.opacity)
            } else if viewModel.answerWindowRemaining > 0 {
                ListenBar(
                    mode: .command,
                    feedback: viewModel.voiceFeedbackPhase,
                    commandHint: viewModel.commandListenerHint,
                    size: compact ? .slim : .full,
                    thinkCountdown: .init(remaining: viewModel.answerWindowRemaining,
                                          total: viewModel.answerWindowTotal)
                )
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .transition(.opacity)
            }

            // Founder 2026-08-03: skip is a secondary escape hatch, not the
            // screen's CTA — a compact centered chip (voice footer's skip
            // styling), no longer a full-width bar competing with the options.
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

    /// Compact MCQ skip chip — mirrors the voice footer's skip styling so the
    /// two modes read the same. Disabled while an answer is being evaluated.
    private var mcqSkipChip: some View {
        Button {
            Task { await viewModel.skipQuestion() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.forward.fill")
                    .font(.system(size: 12, weight: .semibold))
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
        .opacity(isProcessing ? 0.45 : 1)
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
                        // No replay glyph on MCQ: the grid now shares the screen
                        // for the whole question and vertical space is tight — the
                        // whole stem block stays the tap target (#132).
                        HangsQuestionPrompt(
                            text: question.question,
                            barColor: Theme.Hangs.Colors.blue,
                            textFont: stemFont,
                            textIdentifier: "question.text"
                        )
                        // Keep the stem its OWN a11y element inside the replay
                        // button. A button label that resolves to a single
                        // element gets folded into the button, taking the stem's
                        // identifier with it — which is what happened when #132
                        // dropped the speaker glyph that used to be the label's
                        // second element.
                        .accessibilityElement(children: .contain)
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
            metaRow(question: question)
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 4)

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
                                replaySpeakerGlyph
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
                if isProcessing {
                    // 59.6: the typed-answer path (resubmitAnswer → .processing) stays on
                    // QuestionView — it does NOT open the voice AnswerConfirmationView sheet
                    // that owns the only other spinner. Without this branch the screen looked
                    // frozen between "send" and the result. Mirrors the sheet's processingBody.
                    processingRow
                } else {
                    // #131 Track B: the voice countdown lives in the Record/Stop
                    // button. The strip stays for the mute (Track C).
                    audioStrip()

                    QuestionVoiceFooter(
                        viewModel: viewModel,
                        showTextInput: $showTextInput,
                        textAnswer: $textAnswer,
                        isTextFieldFocused: $isTextFieldFocused,
                        compact: compact
                    )
                }
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

    // MARK: - Derived

    private var isRecording: Bool { viewModel.quizState == .recording }

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
