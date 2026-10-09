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
    /// #176: whether TestFlight/Debug-only surfaces may render — here the
    /// provenance + review-badge row under the question. Injected as a plain
    /// Bool (the `QuestionRatingEntry.isEnabled` pattern) so a test can force
    /// both an App Store and a TestFlight build without faking a receipt.
    var debugSurfaces: Bool = BuildChannel.debugSurfacesEnabled()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.hangsCardMotion) private var cardMotion
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
    /// #188 G9: the options' own height, so their scroll region is exactly as
    /// tall as they are while they fit (see `mcqOptions`).
    @State private var optionsHeight: CGFloat = 0
    /// #188 G9: more options below the visible ones — the same cue the stem uses.
    @State private var showOptionsScrollCue = false
    /// #188 G9: the MCQ stem's natural height — its floor grows to it (capped).
    @State private var stemContentHeight: CGFloat = 0
    /// #194: what the card adds around the question (chip row + insets),
    /// measured — it grows with the text size, so it cannot be a constant.
    @State private var stemCardHeight: CGFloat = 0
    @State private var stemRegionHeight: CGFloat = 0
    /// #194 B3: bumped once per question to play the card arrival. Starts at
    /// rest, so a first render (and every snapshot) shows the card in place.
    @State private var cardArrival = 0

    private enum Metrics {
        /// The most of the screen the MCQ question may claim before it scrolls:
        /// under half, so the options always keep the larger share.
        static let stemMaxShare: CGFloat = 0.45
        /// #194 canvas: card, bar, options and buttons share one screen edge.
        static let gutter = Theme.Hangs.Spacing.md
        /// #194 canvas: the gap between the stacked blocks of the screen.
        static let blockGap = Theme.Hangs.Spacing.sm
        /// #194 canvas `.ghost`: the empty slot the next card will land in.
        static let ghostDash = StrokeStyle(lineWidth: 1.5, dash: [6, 6])
        /// The canvas question type has a slightly tighter tracking than SF's default.
        static let questionTracking: CGFloat = -0.4
        /// Canvas: the replay glyph is a 28pt plate, as tall as the category chip.
        static let replayGlyph: CGFloat = 28
        /// Canvas type steps used on this screen: body 17, small label 15.
        static let bodySize: CGFloat = 17
        static let captionSize: CGFloat = 15
    }
    @FocusState private var isTextFieldFocused: Bool
    /// #171 Track E: the answer just submitted for THIS question, echoed by the
    /// evaluating overlay. Written at each submit site the screen owns (tapped MCQ
    /// option, confirmed voice transcript, typed answer) and cleared when the next
    /// question arrives, so a skip can never inherit the previous answer's echo.
    @State private var submittedAnswer = ""

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
                    topChrome

                    if viewModel.quizState == .awaitingQuestion {
                        awaitingQuestionBody
                    } else if let question = viewModel.currentQuestion {
                        if question.isMultipleChoice {
                            mcqBody(question: question, compact: compact, height: geo.size.height)
                        } else {
                            voiceBody(question: question, compact: compact)
                        }
                    } else {
                        Spacer()
                        ProgressView().tint(Theme.Hangs.Colors.action)
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
            if viewModel.isAnswerSheetPresented {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("question.sheetDim")
            }
        }
        // #188 G9: the quiz stops growing at the largest non-accessibility size,
        // so the options and the controls keep a screen to live on. Applied to
        // the screen only — the Settings sheet below is not a quiz screen.
        .dynamicTypeSize(...QuizTypeSize.screenCap)
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
        // #188 G9 (D9): the same bar the result screen draws.
        .quizToolbar(
            // #173 Track A: the toolbar mute is quiz-scoped — it must show the
            // EFFECTIVE mute, not the persisted Settings preference.
            isMuted: viewModel.isAudioMuted,
            isPaused: viewModel.isPaused,
            isPauseEnabled: viewModel.canPauseQuiz || viewModel.isPaused,
            onClose: { showEndQuizConfirmation = true },
            onMute: { Task { await viewModel.toggleMute() } },
            onPause: { viewModel.togglePause() },
            onSettings: { showQuizSettings = true },
            onFeedback: ratingEntry?.isEnabled == true ? ratingEntry?.openFeedback : nil,
            onRateQuestion: rateQuestionAction
        )
        // #155 (TestFlight/Debug only): rate the question. Rating-only — it
        // never reads an answer or moves the quiz state machine.
        .sheet(item: $ratingPresentation) { presentation in
            QuestionRatingSheet(viewModel: presentation.viewModel)
        }
        // #173 C2: the sheet OUTLIVES the confirm tap — it stays up, showing the
        // evaluating state in its own primary button, until the result lands.
        .sheet(isPresented: confirmationSheetBinding, onDismiss: {
            viewModel.handleAnswerConfirmationDismissed()
        }) {
            AnswerConfirmationView(
                isProcessing: viewModel.isAnswerSheetTranscribing,
                transcribedAnswer: $viewModel.transcribedAnswer,
                autoConfirmCountdown: viewModel.autoConfirmCountdown,
                autoConfirmEnabled: viewModel.settings.autoConfirmEnabled,
                autoConfirmTotal: Config.autoConfirmDelaySecs,
                onConfirm: { Task { await viewModel.confirmAnswer() } },
                onReRecord: { viewModel.rerecordAnswer() },
                onEditingBegan: { viewModel.beginEditingTranscript() },
                onCancelEditing: { viewModel.cancelEditingTranscript() },
                onCancel: { viewModel.cancelProcessing() },
                sheetListenerState: viewModel.sheetListenerState,
                commandHint: viewModel.sheetHintWords,
                commandLanguage: viewModel.commandLanguage,
                commandFeedback: viewModel.voiceFeedbackPhase,
                recognizingWord: viewModel.recognizingWord,
                matchedOption: viewModel.matchedVoiceOptionLabel,
                isPaused: viewModel.isPaused,
                evaluatingAnswer: viewModel.isEvaluatingAnswer ? submittedAnswer : nil,
                noAnswerCaptured: viewModel.noAnswerCaptured,
                autoConfirmHeld: viewModel.isAutoConfirmHeld
            )
            // #188 G9: the answer sheet is part of the quiz — same cap.
            .dynamicTypeSize(...QuizTypeSize.screenCap)
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

    // MARK: - Toolbar actions

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

    /// Presentation follows `isAnswerSheetPresented`; a swipe-down only clears
    /// `showAnswerConfirmation` (#173 C2).
    private var confirmationSheetBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isAnswerSheetPresented },
            set: { if !$0 { viewModel.showAnswerConfirmation = false } }
        )
    }

    // MARK: - Top chrome (#173 variant A3)

    /// Under the toolbar: segmented 1-based progress over one small mono meta
    /// row. Replaces BOTH the merged MCQ row and the voice `metaRow` — one
    /// header, every question type.
    private var topChrome: some View {
        VStack(spacing: Theme.Hangs.Spacing.xs) {
            // #194: the category is printed on the card chip, so the header is
            // the one-row progress + counter of the canvas.
            HangsQuizProgressHeader(
                current: viewModel.questionScreenNumber,
                total: viewModel.questionScreenTotal,
                // #122: the fill flips teal for the duration of a matched glow.
                tint: viewModel.voiceFeedbackPhase == .matched
                    ? Theme.Hangs.Colors.liveAccent : nil,
                isRecording: isRecording
            )
            .padding(.top, Theme.Hangs.Spacing.xs)

            if let error = viewModel.errorMessage {
                errorBanner(error)
            }
        }
    }

    // MARK: - #182 Waiting for the next pack question

    /// The player caught up with the pack generator. Calm, large, and obviously
    /// not the end of the quiz — a driver must read it at a glance and know the
    /// set continues on its own. No controls: there is nothing to do but wait,
    /// and the toolbar still offers the way out.
    private var awaitingQuestionBody: some View {
        VStack(spacing: Theme.Hangs.Spacing.md) {
            ProgressView()
                .controlSize(.large)
                .tint(Theme.Hangs.Colors.ink)
            Text("Preparing the next question…")
                .font(.hangsTitle)
                .foregroundStyle(Theme.Hangs.Colors.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("Your pack is still being written. The quiz continues by itself the moment it lands.")
                .font(.hangsBody(Metrics.bodySize))
                .foregroundStyle(Theme.Hangs.Colors.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Hangs.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // #194 Bg-Awaiting: a dashed slot where the next card will land — the
        // set visibly goes on, it is not over.
        .background(
            RoundedRectangle(cornerRadius: Theme.Hangs.Radius.deck, style: .continuous)
                .strokeBorder(Theme.Hangs.Colors.track, style: Metrics.ghostDash)
        )
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, Metrics.blockGap)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("question.awaitingQuestion")
    }

    // MARK: - Error banner

    private func errorBanner(_ error: String) -> some View {
        Label(error, systemImage: "exclamationmark.triangle")
            .font(.hangsBody(Metrics.captionSize, weight: .semibold))
            .foregroundStyle(Theme.Hangs.Colors.error)
            .padding(.horizontal, Theme.Hangs.Spacing.md)
            .padding(.vertical, Theme.Hangs.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Hangs.Radius.cardInner, style: .continuous)
                    .fill(Theme.Hangs.Colors.bgCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Hangs.Radius.cardInner, style: .continuous)
                    .strokeBorder(Theme.Hangs.Colors.error.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal, Metrics.gutter)
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
    ///
    /// #188 G8: `.plain` dimmed the WHOLE label of the disabled button — the
    /// question went half contrast for the entire read/record/evaluate, near
    /// unreadable in light mode. `QuestionReplayButtonStyle` keeps the label at
    /// full contrast; the glyph alone says whether replay is available.
    private func questionReplayTapTarget(@ViewBuilder content: () -> some View) -> some View {
        Button {
            Task { await viewModel.replayQuestionAudio() }
        } label: {
            content()
                .contentShape(Rectangle())
        }
        .buttonStyle(QuestionReplayButtonStyle())
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
            .font(.hangsBody(Metrics.captionSize, weight: .semibold))
            .foregroundStyle(Theme.Hangs.Category.chipText)
            .frame(width: Metrics.replayGlyph, height: Metrics.replayGlyph)
            .background(Circle().fill(Theme.Hangs.Category.chipFill))
            .opacity(viewModel.canReplayAudio ? 1 : 0.4)
            .accessibilityHidden(true)
            .accessibilityIdentifier("question.replayGlyph")
    }

    // MARK: - Question card (#194 "Sklo nad kartami")

    /// The question printed on its category card (R-Question / R-MCQ): the chip
    /// names the category, the replay glyph sits top-right, and the WHOLE card
    /// is the tap-to-replay target, as the question block was before.
    private func questionCard(_ question: Question, @ViewBuilder content: @escaping () -> some View) -> some View {
        questionReplayTapTarget {
            HangsDeckCard(
                categoryId: question.category,
                categoryName: Config.categoryDisplayName(for: question.category),
                categoryIdentifier: "question.category"
            ) {
                replayGlyph
            } content: {
                content()
            }
        }
        .hangsCardArrival(trigger: cardArrival)
        // #194 B3: a new question deals a new card. `.task` runs after the first
        // frame, so the card is drawn in place first (snapshots, Reduce Motion).
        .task(id: question.id) {
            guard cardMotion, !reduceMotion else { return }
            cardArrival += 1
        }
    }

    /// The question in the card's type: the canvas title size, bold, in the
    /// card's own text colour (set by `HangsDeckCard`).
    private func questionText(_ question: Question) -> some View {
        Text(question.question)
            .font(.hangsTitle)
            .tracking(Metrics.questionTracking)
            .minimumScaleFactor(0.7)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            // #188 G9 (D11): display type is already large; past this size it
            // only pushed the question under the scroll cue and starved the options.
            .dynamicTypeSize(...QuizTypeSize.questionCap)
            .accessibilityIdentifier("question.text")
    }

    // MARK: - MCQ body (#125 Variant A "Answer Grid")

    /// The #125 answer-reveal gate is GONE (founder reversed the 2026-07-28
    /// hide-until-the-timer decision on 2026-07-29, #132): on MCQ the driver must
    /// see the options while thinking, so the grid renders from the first frame.
    /// The answer `ListenBar` is NOT part of that reversal — it still claims the
    /// mic is live, so it stays gated on `.recording`.
    private func mcqBody(question: Question, compact: Bool, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            // Merged top row (close + category + counter) lives in `topChrome`
            // now; the MCQ body starts at the stem.
            mcqStem(question: question, compact: compact, screenHeight: height)

            // #176: model · language · review badge, TF/Debug only, under the card.
            QuestionProvenanceRow(
                question: question,
                isEnabled: debugSurfaces,
                horizontalPadding: Metrics.gutter
            )

            // #173 B1 (founder pick): the listening banner sits ABOVE the option
            // grid, directly under the stem — where the eye already is when the
            // countdown starts. Below the grid it was reliably missed (the
            // 2026-09-07 report), and it is the one element that tells the driver
            // the mic is about to open.
            mcqListenBar(question: question, compact: compact)

            mcqOptions(question: question, compact: compact)

            // #188 G9: the "more options below" label gets its own row, so it
            // never sits on option text; the list edge keeps only the fade.
            if showOptionsScrollCue {
                scrollCueLabel
                    .foregroundStyle(Theme.Hangs.Colors.muted)
                    .padding(.trailing, Metrics.gutter)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, Theme.Hangs.Spacing.xxs)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }

            #if DEBUG
                Text(viewModel.quizState.label)
                    .frame(width: 0, height: 0)
                    .accessibilityIdentifier("question.state")
            #endif

            // #179 finding 10: the footer stays PINNED to the bottom edge — four
            // long options once grew past the screen and carried "Skip question"
            // off with them, the driver's only escape hatch. #188 G9: it is the
            // last row of this stack, no longer a bottom inset. The options scroll
            // now, so nothing can push it away; and as an inset it let the
            // options' scroll view run underneath it, where the chip covered the
            // last option (founder screenshot, large text). A row never overlaps.
            mcqFooter(compact: compact)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxHeight: .infinity)
    }

    /// #188 G9 (founder screenshot, xxxLarge): the options are sized to their
    /// content and never squeezed. A plain VStack slot was proposed less height
    /// than four 3–4 line rows need once text was enlarged, and the rows drew
    /// over each other. Now the options sit in their own scroll region that is
    /// exactly as tall as they are, and takes layout priority over the stem, so
    /// the stem keeps only its legibility floor (`mcqStem`) and, past that, the
    /// options scroll instead of overlapping. At default text nothing changes:
    /// the region fits, so it neither scrolls nor bounces.
    private func mcqOptions(question: Question, compact: Bool) -> some View {
        ScrollView(.vertical) {
            MCQOptionPicker(
                options: question.sortedAnswerOptions,
                labels: question.optionLabels,
                onSelect: { key, value in
                    submittedAnswer = value
                    Task { await viewModel.submitMCQAnswer(key: key, value: value) }
                },
                externalSelectedKey: $viewModel.mcqVoiceMatchedKey,
                compact: compact,
                // #174: a tapped option evaluates IN the tile it was tapped on.
                isSubmitting: viewModel.isQuestionScreenBusy
            )
        }
        .scrollBounceBehavior(.basedOnSize)
        // #188 G9 (founder screenshot): at large text option D sat wholly below
        // the fold with nothing saying it existed. The native indicator stays
        // visible and flashes on arrival, and the stem's own overflow cue (fade
        // over the last visible row + "SCROLL ↓") marks that more follow.
        .scrollIndicators(.visible)
        .scrollIndicatorsFlash(onAppear: true)
        // Content height depends on the width only, never on this frame, so
        // feeding it back cannot loop.
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, height in
            optionsHeight = height
        }
        .onScrollGeometryChange(for: Bool.self) { g in
            g.contentOffset.y + g.containerSize.height < g.contentSize.height - 1
        } action: { _, more in
            showOptionsScrollCue = more
        }
        .overlay(alignment: .bottom) {
            if showOptionsScrollCue {
                scrollFade(Theme.Hangs.Colors.bg)
            }
        }
        .frame(maxHeight: optionsHeight > 0 ? optionsHeight : nil)
        .padding(.top, Metrics.blockGap)
        // Outermost on purpose: VStack reads the priority of its direct child.
        .layoutPriority(1)
    }

    /// The pinned MCQ footer: the feedback sweep strip and the skip chip.
    private func mcqFooter(compact: Bool) -> some View {
        VStack(spacing: 0) {
            // #122: light sweep strip — always reserves its 4 pt so the chip
            // below never shifts; glows only during a feedback phase.
            GlowSweepLine(phase: viewModel.voiceFeedbackPhase)
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, Theme.Hangs.Spacing.xs)

            // Founder 2026-08-03: skip is a secondary escape hatch, not the
            // screen's CTA — a compact centered chip (voice footer's skip
            // styling), no longer a full-width bar competing with the options.
            // #174: it STAYS on screen while evaluating (disabled) — the chip is
            // where a skip in flight shows its own spinner now.
            mcqSkipChip(compact: compact)
                .padding(.top, compact ? 8 : 12)
                .padding(.bottom, compact ? 10 : 16)
        }
    }

    /// #132 Track B (variant A "odpočet v lište"): ONE bar slot from the first
    /// countdown tick to submit. #179 D1 widened that slot to the whole question:
    /// the bar is also there while the question is being READ (it was missing
    /// entirely on MCQ — founder screenshot 9) and while the answer is EVALUATED
    /// (it used to vanish, which read as a frozen screen). The state it shows
    /// comes from `QuestionListenPhase`, the same one the open question uses.
    ///
    /// #173 B1: it carries a ✕. Dismissal is scoped to the question on screen
    /// (`ListenBarDismissal`) — nothing is persisted, so the next question arms
    /// its own bar and a driver cannot permanently lose the only surface that
    /// names the voice commands.
    @ViewBuilder
    private func mcqListenBar(question: Question, compact: Bool) -> some View {
        // #185 track B: the retry line sits with the bar (not behind its ✕ —
        // a dismissed bar must not hide why the mic opened again).
        if let prompt = viewModel.emptyAnswerRetryHintPrompt {
            EmptyAnswerRetryHint(prompt: prompt)
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, Metrics.blockGap)
                .transition(.opacity)
        }
        if !listenBarDismissal.isHidden(questionId: question.id),
           let phase = viewModel.listenPhase(for: question)
        {
            QuestionListenBar(
                phase: phase,
                feedback: viewModel.voiceFeedbackPhase,
                recognizingWord: viewModel.recognizingWord,
                showsWords: viewModel.showsCommandWords,
                // #131 Track F folded the old SE-class `compact` flag into the
                // one size axis: a short container gets the slim bar.
                size: compact ? .slim : .full,
                language: viewModel.commandLanguage,
                speechHeard: viewModel.isHearingAnswer,
                inputLevel: viewModel.recordingInputLevel,
                answerRemaining: viewModel.answerWindowRemaining,
                onDismiss: { listenBarDismissal.dismiss(questionId: question.id) }
            )
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, Metrics.blockGap)
            .transition(.opacity)
        }
    }

    /// #179 D3: the shared skip capsule — same shape, same word as the voice
    /// footer's. Disabled while an answer is being evaluated.
    private func mcqSkipChip(compact: Bool) -> some View {
        // #194 R-MCQ: the lone skip capsule is as tall as the voice row's.
        QuestionSkipButton(
            isSkipping: isSkipping,
            isDisabled: viewModel.isQuestionScreenBusy,
            height: compact ? QuestionSkipButton.chipHeight : QuestionSkipButton.compactRowHeight
        ) {
            Task { await viewModel.skipQuestion() }
        }
    }

    // MARK: - MCQ stem (floor + overflow affordance — #125 Variant A)

    /// The stem scroll region: the flexible child of `mcqBody`, so it still takes
    /// every point the options and the pinned footer leave over — but no longer
    /// more. Anything past its height scrolls behind a VISIBLE overflow
    /// affordance — a bottom fade, a "SCROLL ↓" cue, and the native indicator — so
    /// a long stem reads as scrollable, never clipped. The `GeometryReader` +
    /// `minHeight` keeps it from being squeezed to near-zero by the option cards
    /// below (54.2's failure mode).
    ///
    /// #179 finding 10: that floor was 360 (300 on SE-class) — a demand the stem
    /// made of the screen, which four 2–3 line options could not satisfy, so the
    /// footer went off the bottom instead. It is a floor for legibility now, low
    /// enough that the options and the skip chip always fit above it.
    ///
    /// #188 G9 (founder review): at the raised text-size cap the question no
    /// longer fit that floor and slid under the scroll cue while the options
    /// took the screen. The floor now grows to the question's own height, up to
    /// `Metrics.stemMaxShare` of the screen — the whole question stays in view,
    /// and the options scroll behind their cue instead.
    private func mcqStem(question: Question, compact: Bool, screenHeight: CGFloat) -> some View {
        let baseFloor: CGFloat = compact ? 160 : 200
        // #194: the floor is the CARD's, so it counts the card's own chrome
        // (chip row + insets) on top of the question it has to show.
        let chrome = max(0, stemCardHeight - stemRegionHeight)
        let natural = stemContentHeight + chrome
        let floor = max(baseFloor, min(natural, screenHeight * Metrics.stemMaxShare))
        let fill = Theme.Hangs.Category.style(for: question.category)
        return questionCard(question) {
            GeometryReader { geo in
                ScrollView(.vertical) {
                    questionText(question)
                        // Keep the stem its OWN a11y element inside the replay
                        // button. A button label that resolves to a single
                        // element gets folded into the button, taking the stem's
                        // identifier with it.
                        .accessibilityElement(children: .contain)
                        // The stem's NATURAL height, measured before the
                        // min-height frame below — measuring after it would feed
                        // the floor back into itself.
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { stemContentHeight = $0 }
                        // Canvas: a short question sits at the bottom of its card.
                        .frame(minHeight: geo.size.height, alignment: .bottomLeading)
                }
                .scrollIndicators(.visible)
                .scrollPosition($stemScroll)
                .onScrollGeometryChange(for: Bool.self) { g in
                    // Is there more stem below the fold? (taller than the
                    // viewport AND not scrolled to the end.)
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
                        stemOverflowCue(on: fill)
                    }
                }
            }
            // The region's height only depends on the card's, never on the
            // question, so card − region is the chrome and cannot loop.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { stemRegionHeight = $0 }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { stemCardHeight = $0 }
        .frame(minHeight: floor)
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, Metrics.blockGap)
    }

    /// Drift a too-tall stem to its end at reading pace after a short beat
    /// (TF build 53 feedback: "the question text could auto-scroll"). A user
    /// drag interrupts the animation, so manual reading always wins.
    private func autoScrollStemIfNeeded() async {
        stemScroll.scrollTo(edge: .top)
        guard !reduceMotion else { return }
        try? await Task.sleep(for: QuestionStemAutoScroll.readingBeat)
        guard !Task.isCancelled, stemOverflow > 0 else { return }
        withAnimation(.linear(duration: QuestionStemAutoScroll.driftDuration(overflow: stemOverflow))) {
            stemScroll.scrollTo(edge: .bottom)
        }
    }

    /// Bottom fade + a small mono "SCROLL ↓" cue — the visible overflow
    /// affordance of the stem, and since #188 G9 of the options too.
    /// a11y-hidden (peripheral cue), never blocks taps.
    private func stemOverflowCue(on style: Theme.Hangs.Category.Style) -> some View {
        ZStack(alignment: .bottomTrailing) {
            scrollFade(style.fill)
            scrollCueLabel
                .foregroundStyle(style.text)
                .padding(.bottom, Theme.Hangs.Spacing.xxs)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .transition(.opacity)
    }

    /// The bottom fade of a region with more content below, into `color`.
    private func scrollFade(_ color: Color) -> some View {
        LinearGradient(
            colors: [color.opacity(0), color],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 56)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// "SCROLL ↓" in the app language; the caller sets its colour.
    private var scrollCueLabel: some View {
        HStack(spacing: 5) {
            Text("SCROLL")
                .font(.hangsMono(9, weight: .medium))
                .tracking(1.4)
                .textCase(.uppercase)
            Image(systemName: "arrow.down")
                .font(.system(size: 10, weight: .semibold))
        }
    }

    // MARK: - Voice body (frames f9csl / uGhZg)

    private func voiceBody(question: Question, compact: Bool) -> some View {
        VStack(spacing: 0) {
            // #194 R-Question: the question is printed on its category card,
            // which takes every point the pinned controls leave. Only the card's
            // content scrolls, so a long Slovak question can never push the
            // controls off-screen (54.2).
            questionCard(question) {
                GeometryReader { geo in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.md) {
                            // #68: image-type question — image above the text,
                            // scrolls with it. Text/TTS below stays the
                            // driving-mode fallback.
                            if question.hasImage {
                                ImageQuestionView(question: question)
                            }
                            questionText(question)
                        }
                        // Keep the text its own a11y element inside the replay button.
                        .accessibilityElement(children: .contain)
                        // Canvas: a short question sits at the bottom of its card.
                        .frame(minHeight: geo.size.height, alignment: .bottomLeading)
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
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, Metrics.blockGap)

            // #176: model · language · review badge, TF/Debug only. Under the
            // card, not on it: its dev colours are not made for a category fill.
            QuestionProvenanceRow(
                question: question,
                isEnabled: debugSurfaces,
                horizontalPadding: Metrics.gutter
            )

            // Pinned controls below the card — the #131 footer.
            VStack(spacing: Metrics.blockGap) {
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
            .padding(.top, Metrics.blockGap)
            .padding(.bottom, Theme.Hangs.Spacing.md)

            #if DEBUG
                Text(viewModel.quizState.label)
                    .frame(width: 0, height: 0)
                    .accessibilityIdentifier("question.state")
            #endif
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Derived

    private var isRecording: Bool { viewModel.quizState == .recording }

    private var isSkipping: Bool { viewModel.quizState == .skipping }
}

/// #188 G8: the tap-to-replay question block. Unlike `.plain`, it does NOT dim a
/// disabled label — the label is the question itself, and it must read at full
/// contrast in every state. Pressed feedback stays (only an enabled button can
/// be pressed); availability is shown by `replayGlyph` alone.
struct QuestionReplayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

#if DEBUG
    #Preview {
        QuestionView(viewModel: QuizViewModel.preview)
    }
#endif
