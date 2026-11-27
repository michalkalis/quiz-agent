//
//  ResultView.swift
//  Hangs
//
//  Issue #127 — Result screen, Variant C "Zero-Scroll Deck" (founder pick
//  2026-07-28): FIXED zones and no screen-level ScrollView, so the header can
//  never clip — only the explanation scrolls, inside the answer card.
//
//  #224 (founder, TF 2026-11-02, canvas B1b) makes it calm: one neutral card,
//  the answer big, the rest demoted. #248.2 (variant A): the verdict is the
//  card's headline, no category chip. Zone views live in ResultScreenSections /
//  ResultAnswerPanel / ResultFooter. SourceWebView sheet preserved.
//
//  #132 (founder, 2026-07-29): the band's replay-question speaker and the meta
//  row's score/streak stats are gone — one replay affordance ("hear it" on the
//  why card) and no per-question score echo.
//
//  #188 G9 (D9): the top is the question screen's — the native quiz toolbar
//  (✕, sound + pause, ⋯) over `HangsQuizProgressHeader`. The old hand-drawn row
//  (✕ + logo + "03 / 10", TestFlight chips floated on top) broke at large text.
//
//  TF build 90 (founder pick C1, docs/artifacts/tf90-layouts.html): the card is
//  verdict, the question's correct answer, what was heard when it differs, why
//  and the source. The question is one tap away ("Show question" sheet). The
//  STAY/RESUME pill is gone: the toolbar's pause does the same thing.
//

import SwiftUI

struct ResultView: View {
    @ObservedObject var viewModel: QuizViewModel
    /// #155 TestFlight-only rating affordance; nil (the default) = no chip.
    var ratingEntry: QuestionRatingEntry?
    /// #176: whether TestFlight/Debug-only surfaces may render — here the review
    /// badge (and its note) in the meta row. Plain injected Bool so a test can
    /// force either build channel.
    var debugSurfaces: Bool = BuildChannel.debugSurfacesEnabled()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.hangsCardMotion) private var cardMotion
    /// #194 B3: bumped once on appear to deal the result card in. At rest on
    /// the first frame, so snapshots and Reduce Motion show it in place.
    @State private var cardReveal = 0
    // Flipped in .onAppear purely to fire the result haptic once — no longer
    // gates any content (Variant C never hides the answer behind an appear).
    @State private var didAppear = false
    @State private var showSourceWebView = false
    @State private var showEndQuizConfirmation = false
    @State private var showQuizSettings = false
    @State private var showQuestionSheet = false
    /// The ⋯ menu's "Rate question" row (TestFlight/Debug), as on the question screen.
    @State private var ratingPresentation: QuestionRatingPresentation?

    var body: some View {
        ZStack {
            Theme.Hangs.Colors.bg.ignoresSafeArea()

            // NO ScrollView at the screen level — the zones are laid out in a
            // fixed VStack, so nothing can clip under the nav (issue #127).
            VStack(spacing: 0) {
                // #194: one-row header; the category is printed on the card chip.
                HangsQuizProgressHeader(
                    // #79: 1-based index of the question just answered OR
                    // skipped — the same number its question screen showed.
                    // Old backends (no asked_count) fall back to the answered
                    // count, which is incremented before .showingResult.
                    current: viewModel.askedQuestionNumber ?? viewModel.questionsAnswered,
                    total: totalQuestions
                )
                .padding(.top, Theme.Hangs.Spacing.xs)

                // #194 R-Result / R-Wrong: verdict, answer, why and source on
                // ONE card in the question's category colour.
                resultCard
                    .padding(.horizontal, Theme.Hangs.Spacing.md)
                    .padding(.top, Theme.Hangs.Spacing.sm)
                    // TF build 90: the screen's standard gap between the card and Next.
                    .padding(.bottom, Theme.Hangs.Spacing.md)
                    .frame(maxHeight: .infinity)

                ResultFooter(
                    autoAdvanceActive: autoAdvanceActive,
                    countdownRemaining: viewModel.isAwaitingSpokenVerdict
                        ? viewModel.autoAdvanceTotal : viewModel.autoAdvanceCountdown,
                    countdownTotal: viewModel.autoAdvanceTotal,
                    countdownHeld: viewModel.isAwaitingSpokenVerdict,
                    onNext: { viewModel.continueToNext() }
                )
            }
        }
        // #188 G9: same Dynamic Type ceiling as the question screen.
        .dynamicTypeSize(...QuizTypeSize.screenCap)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        // #188 G9 (D9): the question screen's bar, with sound and pause in the
        // same places. Pause here holds the auto-advance (TF build 90: the
        // only pause, the footer's STAY pill duplicated it).
        .quizToolbar(
            isMuted: viewModel.isAudioMuted,
            isPaused: viewModel.isPaused,
            isPauseEnabled: autoAdvanceActive || viewModel.isPaused,
            onClose: confirmEndQuiz,
            onMute: viewModel.isSilentMode ? nil : { Task { await viewModel.toggleMute() } },
            onPause: { viewModel.isPaused ? viewModel.resumeAutoAdvance() : viewModel.pauseQuiz() },
            onSettings: { showQuizSettings = true },
            onFeedback: ratingEntry?.isEnabled == true ? ratingEntry?.openFeedback : nil,
            onRateQuestion: rateQuestionAction
        )
        // #155 (TestFlight/Debug only), via the ⋯ menu since #188 G9 — the
        // floating chips were what the counter collided with.
        .sheet(item: $ratingPresentation) { presentation in
            QuestionRatingSheet(viewModel: presentation.viewModel)
        }
        .sheet(isPresented: $showQuizSettings) {
            SettingsView(viewModel: viewModel)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 4).onChanged { _ in pauseAutoAdvanceIfActive() }
        )
        .simultaneousGesture(
            TapGesture().onEnded { pauseAutoAdvanceIfActive() }
        )
        .sensoryFeedback(resultHaptic, trigger: didAppear)
        .onAppear { didAppear = true }
        .task {
            guard cardMotion, !reduceMotion else { return }
            cardReveal += 1
        }
        .sheet(isPresented: $showQuestionSheet) {
            if let question = resultQuestionModel {
                ResultQuestionSheet(
                    question: question,
                    identity: deckIdentity,
                    correctAnswer: answerText,
                    reveal: optionReveal(for: question)
                )
            }
        }
        .sheet(isPresented: $showSourceWebView) {
            if let sourceUrl = viewModel.resultQuestion?.sourceUrl ?? viewModel.currentQuestion?.sourceUrl {
                SourceWebView(url: sourceUrl, isPresented: $showSourceWebView)
            }
        }
        // #81 follow-up (founder 2026-07-06): the X must confirm before quitting.
        .alert("End Quiz?", isPresented: $showEndQuizConfirmation) {
            Button("Continue", role: .cancel, action: viewModel.releaseQuestionAfterModal)
            Button("End Quiz", role: .destructive) {
                Task { await viewModel.endQuiz() }
            }
        }
    }

    /// #243.13: the dialog holds the auto-advance, as on the question.
    private func confirmEndQuiz() {
        viewModel.holdQuestionForModal()
        showEndQuizConfirmation = true
    }

    /// The #155 gate: TestFlight/Debug only, and only with a question to rate —
    /// `resultQuestion` first so an advanced quiz can't re-target the rating.
    private var resultQuestionModel: Question? { viewModel.resultQuestion ?? viewModel.currentQuestion }

    /// #198: the playing pack's colour, else the question's category.
    private var deckIdentity: DeckIdentity {
        DeckIdentity(
            category: resultQuestionModel?.category,
            packId: viewModel.activePackId ?? resultQuestionModel?.packId
        )
    }

    /// #224 (canvas B1b): a neutral card for every verdict; the only green is a
    /// right answer.
    private var resultCard: some View {
        // #248.2 (founder 2026-11-25, variant A): no category on the card; the
        // verdict is its headline, then the answer, what the player said, why.
        ResultCardSurface {
            VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.sm) {
                ResultVerdictLabel(verdict: verdict, streak: viewModel.resultStreak)
                ResultAnswerPanel(
                    answerLabel: answerLabel,
                    answerText: answerText,
                    isRecap: isRecap,
                    isCorrect: verdict == .correct,
                    explanation: explanationText,
                    saidLine: saidLine,
                    hearItFailed: viewModel.readAloudFailure == .explanation,
                    onHearIt: viewModel.isSilentMode ? nil : { if let explanationText { viewModel.readExplanationAloud(explanationText) } },
                    showsHearItChip: !viewModel.readsExplanationOnResult
                )
                ResultMetaRow(
                    sourceDomain: sourceDomain,
                    crowd: isRecap ? nil : viewModel.resultCrowd,
                    reviewBadge: reviewBadge,
                    reviewNote: reviewNote,
                    onShowQuestion: showQuestionAction,
                    onOpenSource: { showSourceWebView = true }
                )
            }
        }
        .hangsCardArrival(trigger: cardReveal)
    }

    /// Recap has none: the question is already the card's text.
    private var showQuestionAction: (() -> Void)? {
        guard !isRecap else { return nil }
        return {
            viewModel.openResultQuestion()
            showQuestionSheet = true
        }
    }

    /// MCQ only: the correct option and, on a miss, the one the player chose.
    private func optionReveal(for question: Question) -> MCQOptionPicker.Reveal? {
        guard !question.sortedAnswerOptions.isEmpty, let evaluation = viewModel.resultEvaluation else { return nil }
        let correctKey = question.optionKey(matching: evaluation.correctAnswer)
        let chosenKey = evaluation.wasSkipped ? nil : question.optionKey(matching: evaluation.userAnswer)
        return MCQOptionPicker.Reveal(correctKey: correctKey, chosenKey: chosenKey)
    }

    private var rateQuestionAction: (() -> Void)? {
        guard let ratingEntry, ratingEntry.isEnabled,
              let questionId = (viewModel.resultQuestion ?? viewModel.currentQuestion)?.id
        else { return nil }
        let questionText = questionStem
        return {
            ratingPresentation = QuestionRatingPresentation(
                viewModel: ratingEntry.makeViewModel(questionId, questionText)
            )
        }
    }

    // MARK: - Verdict / answer derivation

    private var verdict: ResultVerdict {
        // The recap fallback (nil evaluation OR an empty answer) is one coherent
        // degraded state: a neutral field — never a confident "MISSED IT." verdict
        // over an answer we cannot show (req. 6 nil-eval + req. 7 empty-answer).
        guard !isRecap, let evaluation = viewModel.resultEvaluation else { return .neutral }
        // #131 Track D: a skip is not a failure — it must never fall through to
        // `.incorrect` and render "MISSED IT. / incorrect" over an answer the
        // driver never gave.
        if evaluation.wasSkipped { return .skipped }
        return evaluation.isCorrect ? .correct : .incorrect
    }

    /// The big answer: always the question's correct answer, also when the
    /// player's was accepted (TF build 90: an accepted "solo" was printed as
    /// the answer to a question whose answer is "soľ"). Only a backend that sent
    /// no correct answer falls back to the accepted one. Empty in the neutral path.
    private var canonicalAnswer: String {
        guard let evaluation = viewModel.resultEvaluation else { return "" }
        if revealedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, evaluation.isCorrect {
            return evaluation.userAnswer
        }
        return revealedAnswer
    }

    /// Recap fallback: nil evaluation OR an empty canonical answer. The question
    /// stem becomes the dominant text instead of an empty 46pt row (req. 6 & 7).
    private var isRecap: Bool {
        viewModel.resultEvaluation == nil
            || canonicalAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var answerLabel: LocalizedStringKey {
        isRecap ? "the question" : "Correct answer"
    }

    private var answerText: String {
        isRecap ? questionStem ?? "" : mcqLabelled(canonicalAnswer)
    }

    /// #132 letter+text pairing ("B — Pyramid") — logic lives in
    /// `Question.labelledAnswer` (shared with the #132 E recap capture).
    private func mcqLabelled(_ raw: String) -> String {
        guard let question = viewModel.resultQuestion ?? viewModel.currentQuestion
        else { return raw }
        return question.labelledAnswer(raw)
    }

    /// "Your answer", under the right one: struck through on a miss; on an
    /// accepted answer only when it is worded differently (#248.2); never on a
    /// skip (#131 Track D: nothing was said).
    private var saidLine: ResultAnswerPanel.SaidLine? {
        guard let said = viewModel.resultEvaluation?.userAnswer,
              !said.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        switch verdict {
        // #250: an option key reads as the card's "C — text", like the answer.
        case .incorrect, .neutral: return .missed(mcqLabelled(said))
        case .correct: return heardDiffers(said) ? .heard(mcqLabelled(said)) : nil
        case .skipped: return nil
        }
    }

    /// Whether the player's answer reads differently from the answer on the card:
    /// case, accents and surrounding spaces don't count, and on MCQ a key and
    /// its option text are the same answer.
    private func heardDiffers(_ said: String) -> Bool {
        if let question = resultQuestionModel, let saidKey = question.optionKey(matching: said) {
            return saidKey != question.optionKey(matching: canonicalAnswer)
        }
        return Self.comparable(said) != Self.comparable(canonicalAnswer)
    }

    private static func comparable(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private var questionStem: String? {
        viewModel.resultQuestion?.question ?? viewModel.currentQuestion?.question
    }

    /// #252 (founder 2026-11-27): the quick game shows only right or wrong.
    /// A recap row the player opened on purpose keeps its explanation.
    private var showsWhyAndSource: Bool {
        isRecap || viewModel.resultShowsExplanation
    }

    /// Inline explanation source: the question's `explanation`, falling back to
    /// the evaluation's. Empty/nil hides the whole "why" block on BOTH outcomes.
    private var explanationText: String? {
        guard showsWhyAndSource else { return nil }
        let raw = viewModel.resultQuestion?.explanation
            ?? viewModel.currentQuestion?.explanation
            ?? viewModel.resultEvaluation?.explanation
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return raw
    }

    /// Host of the source URL ("nasa.gov"), or nil when no source exists — the
    /// source line is gated on the URL only, never on correctness (issue #127
    /// root cause 1: the old `if isCorrect` gate dies).
    private var sourceDomain: String? {
        guard showsWhyAndSource else { return nil }
        return HangsSourceLink.domain(
            from: viewModel.resultQuestion?.sourceUrl ?? viewModel.currentQuestion?.sourceUrl
        )
    }

    /// #176: the review badge of the question just answered — TF/Debug only,
    /// and `resultQuestion` first so a prefetched next question can never label
    /// the answer on screen.
    private var reviewBadge: String? {
        guard debugSurfaces else { return nil }
        let badge = (viewModel.resultQuestion ?? viewModel.currentQuestion)?.reviewBadge
        // #250 (founder 2026-11-26): a vouched question's silent green dot
        // read as an unexplained element; the result shows only a badge that
        // asks for a check. The question screen keeps the dot.
        return badge == "approved" ? nil : badge
    }

    /// The gate's objection, one line. Only ever sent by the backend for the
    /// flagged/critical states, so no client-side state filter is needed.
    private var reviewNote: String? {
        guard debugSurfaces else { return nil }
        let note = (viewModel.resultQuestion ?? viewModel.currentQuestion)?.reviewNote
        guard let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return note
    }

    // MARK: - Footer state

    /// #113 S6a: "active" = not paused && still ticking (no Settings toggle).
    /// #240.9: also while the verdict is spoken (the countdown waits for it).
    private var autoAdvanceActive: Bool {
        !viewModel.isPaused && (viewModel.autoAdvanceCountdown > 0 || viewModel.isAwaitingSpokenVerdict)
    }

    private func pauseAutoAdvanceIfActive() {
        guard autoAdvanceActive else { return }
        viewModel.pauseQuiz()
    }

    // MARK: - Derived

    /// The answer surfaced as the correct answer. Open questions reveal the short
    /// `headlineAnswer` gist (what the evaluator scores against); closed questions
    /// carry no gist, so this falls back to the full `correctAnswer` (46.B9).
    /// Internal for tests — the reveal logic is asserted here directly.
    var revealedAnswer: String {
        guard let evaluation = viewModel.resultEvaluation else { return "" }
        return evaluation.headlineAnswer ?? evaluation.correctAnswer
    }

    private var totalQuestions: Int {
        // 54.10: fall back to the configured length, not a hardcoded 10.
        viewModel.currentSession?.maxQuestions ?? viewModel.settings.numberOfQuestions
    }

    private var resultHaptic: SensoryFeedback {
        guard let evaluation = viewModel.resultEvaluation else { return .impact }
        return Self.haptic(for: evaluation.result)
    }

    /// #188 G5 (founder 2026-10-06): a miss is met as mildly as the verdict
    /// band shows it — one soft tap, never the triple error buzz.
    static let missHaptic = SensoryFeedback.impact(flexibility: .soft, intensity: 0.6)

    /// Pure mapping so the skip-is-not-a-failure decision is testable.
    static func haptic(for result: Evaluation.EvaluationResult) -> SensoryFeedback {
        switch result {
        case .correct: return .success
        case .incorrect, .partiallyCorrect, .partiallyIncorrect: return missHaptic
        // #82 item 2 (decision 7): a skip is not a failure — gentle tick.
        case .skipped: return .selection
        // #148: a verdict this build does not know — neutral, never a failure buzz.
        case .unknown: return .impact
        }
    }
}

#if DEBUG
    #Preview {
        ResultView(viewModel: QuizViewModel.previewWithEvaluation)
    }
#endif
