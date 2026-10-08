//
//  ResultView.swift
//  Hangs
//
//  Issue #127 — Result screen, Variant C "Zero-Scroll Deck" (founder pick
//  2026-07-28): FIXED zones and no screen-level ScrollView, so the header can
//  never clip — only the explanation scrolls, inside the answer card.
//
//  #131 Track D, Variant A "Verdikt vládne" (founder pick 2026-07-29) re-ranks
//  those zones: a dominant full-bleed verdict band first, the answer card
//  second, and ONE muted mono meta row (you said · source) third. Zone views
//  live in ResultScreenSections / ResultAnswerPanel / ResultFooter.
//  SourceWebView sheet preserved.
//
//  #132 (founder, 2026-07-29): the band's replay-question speaker and the meta
//  row's score/streak stats are gone — one replay affordance ("hear it" on the
//  why card) and no per-question score echo.
//
//  #188 G9 (D9): the top is the question screen's — the native quiz toolbar
//  (✕, sound + pause, ⋯) over `HangsQuizProgressHeader`. The old hand-drawn row
//  (✕ + logo + "03 / 10", TestFlight chips floated on top) broke at large text.
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
    // Flipped in .onAppear purely to fire the result haptic once — no longer
    // gates any content (Variant C never hides the answer behind an appear).
    @State private var didAppear = false
    @State private var showSourceWebView = false
    @State private var showEndQuizConfirmation = false
    @State private var showQuizSettings = false
    /// The ⋯ menu's "Rate question" row (TestFlight/Debug), as on the question screen.
    @State private var ratingPresentation: QuestionRatingPresentation?

    var body: some View {
        ZStack {
            Theme.Hangs.Colors.bg.ignoresSafeArea()

            // NO ScrollView at the screen level — the zones are laid out in a
            // fixed VStack, so nothing can clip under the nav (issue #127).
            VStack(spacing: 0) {
                HangsQuizProgressHeader(
                    category: (viewModel.resultQuestion ?? viewModel.currentQuestion)
                        .map { Config.categoryDisplayName(for: $0.category) } ?? "",
                    // #79: 1-based index of the question just answered OR
                    // skipped — the same number its question screen showed.
                    // Old backends (no asked_count) fall back to the answered
                    // count, which is incremented before .showingResult.
                    current: viewModel.askedQuestionNumber ?? viewModel.questionsAnswered,
                    total: totalQuestions
                )
                .padding(.top, Theme.Hangs.Spacing.xs)
                .padding(.bottom, Theme.Hangs.Spacing.sm)

                // Rank 1 — the verdict, edge to edge (Variant A).
                ResultVerdictBand(verdict: verdict)

                // Rank 2 — the answer + why, filling whatever is left.
                ResultAnswerPanel(
                    answerLabel: answerLabel,
                    answerText: answerText,
                    isRecap: isRecap,
                    explanation: explanationText,
                    onHearIt: { if let explanationText { viewModel.readExplanationAloud(explanationText) } }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, Theme.Hangs.Spacing.xl)
                .padding(.top, 10)

                // Rank 3 — everything else, in one quiet line.
                ResultMetaRow(
                    userAnswer: metaUserAnswer,
                    sourceDomain: sourceDomain,
                    reviewBadge: reviewBadge,
                    reviewNote: reviewNote,
                    onOpenSource: { showSourceWebView = true }
                )
                .padding(.horizontal, Theme.Hangs.Spacing.xl)
                .padding(.top, Theme.Hangs.Spacing.xs)

                ResultFooter(
                    feedbackPhase: viewModel.voiceFeedbackPhase,
                    recognizingWord: viewModel.recognizingWord,
                    isListeningForCommands: viewModel.commandListenerHint != nil,
                    commandHint: viewModel.voiceHintWords,
                    commandLanguage: viewModel.commandLanguage,
                    autoAdvanceActive: autoAdvanceActive,
                    isPaused: viewModel.isPaused,
                    countdownRemaining: viewModel.autoAdvanceCountdown,
                    countdownTotal: viewModel.settings.autoAdvanceDelay,
                    onNext: { viewModel.continueToNext() },
                    onStay: { viewModel.pauseQuiz() },
                    onResume: { viewModel.resumeAutoAdvance() }
                )
            }
        }
        // #188 G9: same Dynamic Type ceiling as the question screen.
        .dynamicTypeSize(...QuizTypeSize.screenCap)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        // #188 G9 (D9): the question screen's bar, with sound and pause in the
        // same places. Pause here holds the auto-advance (the STAY pill's job).
        .quizToolbar(
            isMuted: viewModel.isAudioMuted,
            isPaused: viewModel.isPaused,
            isPauseEnabled: autoAdvanceActive || viewModel.isPaused,
            onClose: { showEndQuizConfirmation = true },
            onMute: { Task { await viewModel.toggleMute() } },
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
        .sheet(isPresented: $showSourceWebView) {
            if let sourceUrl = viewModel.resultQuestion?.sourceUrl ?? viewModel.currentQuestion?.sourceUrl {
                SourceWebView(url: sourceUrl, isPresented: $showSourceWebView)
            }
        }
        // #81 follow-up (founder 2026-07-06): the X must confirm before quitting.
        .alert("End Quiz?", isPresented: $showEndQuizConfirmation) {
            Button("Continue", role: .cancel) {}
            Button("End Quiz", role: .destructive) {
                Task { await viewModel.endQuiz() }
            }
        }
    }

    /// The #155 gate: TestFlight/Debug only, and only with a question to rate —
    /// `resultQuestion` first so an advanced quiz can't re-target the rating.
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
        // `.incorrect` and render "MISSED IT. / not quite" over an answer the
        // driver never gave.
        if evaluation.wasSkipped { return .skipped }
        return evaluation.isCorrect ? .correct : .incorrect
    }

    /// The 46pt answer: the user's (correct) answer on a correct result, the
    /// revealed correct answer on a wrong one. Empty in the neutral path.
    private var canonicalAnswer: String {
        guard let evaluation = viewModel.resultEvaluation else { return "" }
        return evaluation.isCorrect ? evaluation.userAnswer : revealedAnswer
    }

    /// Recap fallback: nil evaluation OR an empty canonical answer. The question
    /// stem becomes the dominant text instead of an empty 46pt row (req. 6 & 7).
    private var isRecap: Bool {
        viewModel.resultEvaluation == nil
            || canonicalAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var answerLabel: LocalizedStringKey {
        if isRecap { return "the question" }
        return verdict == .correct ? "your answer" : "the answer"
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

    /// "you said" belongs in the meta row only when the driver actually said
    /// something that was wrong — never on a correct answer (it is already the
    /// headline answer) and never on a skip (#131 Track D: nothing was said).
    private var metaUserAnswer: String? {
        guard verdict == .incorrect || verdict == .neutral,
              let said = viewModel.resultEvaluation?.userAnswer,
              !said.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return said
    }

    private var questionStem: String? {
        viewModel.resultQuestion?.question ?? viewModel.currentQuestion?.question
    }

    /// Inline explanation source: the question's `explanation`, falling back to
    /// the evaluation's. Empty/nil hides the whole "why" block on BOTH outcomes.
    private var explanationText: String? {
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
        HangsSourceLink.domain(
            from: viewModel.resultQuestion?.sourceUrl ?? viewModel.currentQuestion?.sourceUrl
        )
    }

    /// #176: the review badge of the question just answered — TF/Debug only,
    /// and `resultQuestion` first so a prefetched next question can never label
    /// the answer on screen.
    private var reviewBadge: String? {
        guard debugSurfaces else { return nil }
        return (viewModel.resultQuestion ?? viewModel.currentQuestion)?.reviewBadge
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
    private var autoAdvanceActive: Bool {
        !viewModel.isPaused && viewModel.autoAdvanceCountdown > 0
    }

    private func pauseAutoAdvanceIfActive() {
        guard !viewModel.isPaused,
              viewModel.autoAdvanceCountdown > 0 else { return }
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
