//
//  ResultView.swift
//  Hangs
//
//  Issue #127 — Result screen, Variant C "Zero-Scroll Deck" (founder pick
//  2026-07-28). Three FIXED zones and no screen-level ScrollView, so the header
//  can never clip: chrome (nav + progress), a colour-washed verdict field
//  (verdict word + inline score), and an answer panel that fills the rest — the
//  explanation scrolls INSIDE the panel (founder modification) rather than the
//  screen. The footer consolidates to a docked glow + CmdListenBar + one row
//  (STAY/RESUME pill next to the "Next question" CTA). Zone views live in the
//  sibling ResultScreenSections.swift. SourceWebView sheet preserved.
//

import SwiftUI

struct ResultView: View {
    @ObservedObject var viewModel: QuizViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Flipped in .onAppear purely to fire the result haptic once — no longer
    // gates any content (Variant C never hides the answer behind an appear).
    @State private var didAppear = false
    @State private var showSourceWebView = false
    @State private var showEndQuizConfirmation = false

    var body: some View {
        ZStack {
            Theme.Hangs.Colors.bg.ignoresSafeArea()

            // NO ScrollView at the screen level — the three zones are laid out in
            // a fixed VStack, so nothing can clip under the nav (issue #127).
            VStack(spacing: 0) {
                HangsQuizNav(
                    onClose: { showEndQuizConfirmation = true },
                    counterText: counterString
                )
                HangsProgressBar(progress: progressFraction)

                VStack(spacing: 10) {
                    ResultVerdictField(
                        verdict: verdict,
                        scoreValue: formattedScore,
                        scoreDelta: scoreDelta
                    )
                    ResultAnswerPanel(
                        verdict: verdict,
                        answerLabel: answerLabel,
                        answerText: answerText,
                        isRecap: isRecap,
                        explanation: explanationText,
                        questionStem: questionStem,
                        userAnswer: viewModel.resultEvaluation?.userAnswer,
                        sourceDomain: sourceDomain,
                        onReadAloud: { Task { await viewModel.replayQuestionAudio() } },
                        onHearIt: { Task { await viewModel.replayFeedbackAudio() } },
                        onOpenSource: { showSourceWebView = true }
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 10)

                ResultFooter(
                    feedbackPhase: viewModel.voiceFeedbackPhase,
                    commandHint: viewModel.commandListenerHint,
                    autoAdvanceActive: autoAdvanceActive,
                    isPaused: viewModel.currentQuestionPaused,
                    countdownRemaining: viewModel.autoAdvanceCountdown,
                    countdownTotal: viewModel.settings.autoAdvanceDelay,
                    onNext: { viewModel.continueToNext() },
                    onStay: { viewModel.pauseQuiz() },
                    onResume: { viewModel.resumeAutoAdvance() }
                )
            }
        }
        .interactiveMinimize(isMinimized: $viewModel.isMinimized, canMinimize: viewModel.canMinimize)
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
        isRecap ? questionStem ?? "" : canonicalAnswer
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
        let urlString = viewModel.resultQuestion?.sourceUrl ?? viewModel.currentQuestion?.sourceUrl
        guard let urlString, let host = URL(string: urlString)?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Scorebox delta: the earned points on a correct answer, "+0" otherwise;
    /// hidden entirely in the neutral path. Mirrors the old statsRow suffix.
    private var scoreDelta: String? {
        switch verdict {
        case .correct: return pointsDeltaSuffix
        case .incorrect, .skipped: return "+0"
        case .neutral: return nil
        }
    }

    // MARK: - Footer state

    /// #113 S6a: "active" = not paused && still ticking (no Settings toggle).
    private var autoAdvanceActive: Bool {
        !viewModel.currentQuestionPaused && viewModel.autoAdvanceCountdown > 0
    }

    private func pauseAutoAdvanceIfActive() {
        guard !viewModel.currentQuestionPaused,
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

    private var counterString: String {
        // #79: 1-based index of the question just answered (questionsAnswered is
        // already incremented before .showingResult — keep in lockstep with QuestionView).
        String(format: "%02d / %02d", viewModel.questionsAnswered, totalQuestions)
    }

    private var progressFraction: Double {
        guard totalQuestions > 0 else { return 0 }
        return Double(viewModel.questionsAnswered) / Double(totalQuestions)
    }

    private var pointsDelta: Double {
        viewModel.resultEvaluation?.points ?? 0
    }

    private var pointsDeltaSuffix: String {
        let pts = pointsDelta
        let sign = pts >= 0 ? "+" : ""
        if pts == pts.rounded() {
            return "\(sign)\(Int(pts))"
        }
        return String(format: "%@%.1f", sign, pts)
    }

    private var formattedScore: String {
        let score = viewModel.score
        if score >= 1000 {
            return String(format: "%.1fk", score / 1000)
        }
        if score == score.rounded() {
            return "\(Int(score))"
        }
        return String(format: "%.1f", score)
    }

    private var resultHaptic: SensoryFeedback {
        guard let evaluation = viewModel.resultEvaluation else { return .impact }
        return Self.haptic(for: evaluation.result)
    }

    /// Pure mapping so the skip-is-not-a-failure decision is testable.
    static func haptic(for result: Evaluation.EvaluationResult) -> SensoryFeedback {
        switch result {
        case .correct: return .success
        case .incorrect: return .error
        // #82 item 2 (decision 7): a skip is not a failure — gentle tick.
        case .skipped: return .selection
        case .partiallyCorrect, .partiallyIncorrect: return .warning
        }
    }
}

#if DEBUG
    #Preview {
        ResultView(viewModel: QuizViewModel.previewWithEvaluation)
    }
#endif
