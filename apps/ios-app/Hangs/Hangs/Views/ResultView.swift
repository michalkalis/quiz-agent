//
//  ResultView.swift
//  Hangs
//
//  Pencil Result screen — correct (X4o4l) and incorrect (31AzE) variants.
//  bg-page background, editorial Anton headline, answer comparison card,
//  score stat box (#84 dropped the streak box — logic kept in QuizStats),
//  and a footer CTA carrying the auto-advance countdown inside it (#108B).
//  Source web-view sheet preserved from original design.
//

import SwiftUI

struct ResultView: View {
    @ObservedObject var viewModel: QuizViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showEvaluation = false
    @State private var showSourceWebView = false
    @State private var showEndQuizConfirmation = false

    var body: some View {
        ZStack {
            Theme.Hangs.Colors.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                HangsQuizNav(
                    onClose: { showEndQuizConfirmation = true },
                    counterText: counterString
                )
                HangsProgressBar(progress: progressFraction)

                ScrollView {
                    VStack(spacing: 0) {
                        heroBlock

                        if showEvaluation, viewModel.resultEvaluation != nil {
                            answerCard
                                .padding(.horizontal, 24)
                                .padding(.top, 8)

                            statsRow
                                .padding(.horizontal, 24)
                                .padding(.top, 12)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                footerBar
            }
        }
        .interactiveMinimize(isMinimized: $viewModel.isMinimized, canMinimize: viewModel.canMinimize)
        .simultaneousGesture(
            DragGesture(minimumDistance: 4).onChanged { _ in pauseAutoAdvanceIfActive() }
        )
        .simultaneousGesture(
            TapGesture().onEnded { pauseAutoAdvanceIfActive() }
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: showEvaluation)
        .sensoryFeedback(resultHaptic, trigger: showEvaluation)
        .onAppear { showEvaluation = true }
        .sheet(isPresented: $showSourceWebView) {
            if let sourceUrl = viewModel.resultQuestion?.sourceUrl {
                SourceWebView(url: sourceUrl, isPresented: $showSourceWebView)
            }
        }
        // #81 follow-up (founder 2026-07-06): the X must confirm before quitting —
        // same native alert as QuestionView / MinimizedQuizView (frame w9tOoU).
        .alert("End Quiz?", isPresented: $showEndQuizConfirmation) {
            Button("Continue", role: .cancel) {}
            Button("End Quiz", role: .destructive) {
                Task { await viewModel.endQuiz() }
            }
        }
    }

    // MARK: - Hero

    private var heroBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                HangsResultBanner(kind: isCorrect ? .correct : .incorrect)
                    .accessibilityIdentifier("result.heroBanner")
                Spacer()
                readAloudButton
            }
            // #96 P3 (founder no-wrap): one line — was the stacked "NAILED\nIT."
            // / "MISSED\nIT."; scales down instead of wrapping.
            Text(isCorrect ? "NAILED IT." : "MISSED IT.")
                .font(.hangsDisplay(52))
                .tracking(-2)
                .foregroundColor(Theme.Hangs.Colors.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(subHeadline)
                .font(.hangsBody(14, weight: .medium))
                .foregroundColor(Theme.Hangs.Colors.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var readAloudButton: some View {
        Button {
            // 59.7 Bug A: use the timer-safe `replayQuestionAudio()` — `playQuestionAudio`
            // is the question-screen flow function (it tears down silence detection and
            // re-arms the think/answer timers), which is wrong on the result screen and can
            // silently drop playback. `replayQuestionAudio()` reads the URL internally and
            // leaves the running auto-advance countdown untouched.
            Task { await viewModel.replayQuestionAudio() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 11, weight: .semibold))
                Text("read aloud")
                    .font(.hangsMono(11, weight: .semibold))
                    .tracking(2)
            }
            .foregroundColor(Theme.Hangs.Colors.blue)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("result.readAloud")
    }

    // MARK: - Answer card

    @ViewBuilder
    private var answerCard: some View {
        if let evaluation = viewModel.resultEvaluation {
            if evaluation.isCorrect {
                HangsAnswerComparisonCard(
                    primaryLabel: "YOUR ANSWER",
                    primaryValue: evaluation.userAnswer,
                    primaryValueColor: Theme.Hangs.Colors.ink,
                    primaryBadge: .correct,
                    secondaryLabel: "THE QUESTION",
                    secondaryValue: viewModel.resultQuestion?.question ?? "",
                    secondaryValueColor: Theme.Hangs.Colors.muted,
                    secondaryBadge: nil,
                    primaryValueFont: .hangsDisplay(32, weight: .black),
                    secondaryValueFont: .hangsBody(15, weight: .medium)
                )
            } else {
                HangsAnswerComparisonCard(
                    primaryLabel: "YOU SAID",
                    primaryValue: evaluation.userAnswer,
                    primaryValueColor: Theme.Hangs.Colors.mutedFaint,
                    primaryBadge: .incorrect,
                    secondaryLabel: "THE ANSWER",
                    secondaryValue: revealedAnswer,
                    secondaryValueColor: Theme.Hangs.Colors.ink,
                    secondaryBadge: .correct,
                    primaryValueFont: .hangsDisplay(26, weight: .black),
                    secondaryValueFont: .hangsDisplay(30, weight: .black)
                )
            }
        }
    }

    // MARK: - Stats row

    /// #84: streak box removed (founder decision 5) — only the score box remains.
    /// Streak keeps computing in QuizStats; it's just no longer displayed.
    private var statsRow: some View {
        HangsStatBox(
            label: "score",
            value: formattedScore,
            labelColor: Theme.Hangs.Colors.pink,
            valueColor: Theme.Hangs.Colors.ink,
            suffix: isCorrect ? pointsDeltaSuffix : "+0",
            inlineSuffix: true,
            compact: true
        )
    }

    // MARK: - Footer

    /// #108B: auto-advance countdown lives inside the "Next question" CTA
    /// (Waze-like drain + "Ns" chip, pen `ilWTA`/`4EBgp`) — the separate
    /// "Next in Ns" bar is gone.
    /// #113 S6a deleted the `autoAdvanceEnabled` axis (write-only-true — no
    /// Settings toggle ever existed), so "active" = not paused && still ticking.
    private var autoAdvanceActive: Bool {
        !viewModel.currentQuestionPaused
            && viewModel.autoAdvanceCountdown > 0
    }

    private var footerBar: some View {
        VStack(spacing: 10) {
            // #77/#96 P2: listening indicator (pen `s49sd`) — result command
            // window ("next"). Shown only while armed.
            if let hint = viewModel.commandListenerHint {
                CmdListenBar(hint: hint)
                    .transition(.opacity)
            }

            HangsPrimaryButton(
                title: "Next question",
                icon: nil,
                trailingIcon: "arrow.right",
                height: 64,
                countdownSecondsRemaining: autoAdvanceActive ? viewModel.autoAdvanceCountdown : nil,
                countdownTotal: viewModel.settings.autoAdvanceDelay
            ) {
                viewModel.continueToNext()
            }
            .accessibilityLabel(autoAdvanceActive
                ? String(localized: "Next question, auto-advancing in \(viewModel.autoAdvanceCountdown) seconds", comment: "Accessibility label for the next-question button while auto-advance counts down")
                : String(localized: "Next question", comment: "Accessibility label for the next-question button"))
            .accessibilityIdentifier("result.continue")

            if autoAdvanceActive {
                // #81: full-size secondary button (44pt target) — the tiny text
                // link was the only way to linger on a result while driving.
                HangsSecondaryButton(title: "Stay here", height: 44) {
                    viewModel.pauseQuiz()
                }
                .accessibilityIdentifier("result.stayHere")
            }

            if isCorrect, viewModel.resultQuestion?.sourceUrl != nil {
                HangsGhostButton(
                    title: "Why is this correct?",
                    icon: "book.closed",
                    color: Theme.Hangs.Colors.blue
                ) {
                    showSourceWebView = true
                }
                .accessibilityIdentifier("result-why-correct-button")
            }

            if viewModel.currentQuestionPaused {
                HangsGhostButton(
                    title: "Resume auto-advance",
                    icon: "play.fill",
                    color: Theme.Hangs.Colors.muted
                ) {
                    // 59.8: resume the countdown (stay on the result), NOT continueToNext()
                    // which is the "Next question" action and jumps straight to the next Q.
                    viewModel.resumeAutoAdvance()
                }
                .accessibilityIdentifier("result-resume-auto-advance-button")
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
    }

    // MARK: - Derived

    private func pauseAutoAdvanceIfActive() {
        guard !viewModel.currentQuestionPaused,
              viewModel.autoAdvanceCountdown > 0 else { return }
        viewModel.pauseQuiz()
    }

    private var isCorrect: Bool {
        viewModel.resultEvaluation?.isCorrect ?? false
    }

    /// The answer surfaced in "THE ANSWER" card. Open questions reveal the short
    /// `headlineAnswer` gist (the field the evaluator scores against); closed
    /// questions carry no gist, so this falls back to the full `correctAnswer`,
    /// leaving the existing reveal path unchanged (46.B9). Internal for tests:
    /// the answer card sits behind the `showEvaluation` @State gate, which
    /// ViewInspector cannot flip, so the reveal logic is asserted here directly.
    var revealedAnswer: String {
        guard let evaluation = viewModel.resultEvaluation else { return "" }
        return evaluation.headlineAnswer ?? evaluation.correctAnswer
    }

    private var totalQuestions: Int {
        // 54.10: fall back to the configured length (matching CompletionView /
        // QuestionView), not a hardcoded 10 — a non-10 session showed a wrong total.
        viewModel.currentSession?.maxQuestions ?? viewModel.settings.numberOfQuestions
    }

    private var counterString: String {
        // #79: shows the 1-based index of the question just answered. Raw
        // `questionsAnswered` (no +1) is correct HERE because handleQuizResponse
        // already incremented it before transitioning to .showingResult — this
        // renders the SAME number QuestionView showed for the same question
        // (there it is pre-increment, so it adds +1). Keep the two in lockstep.
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

    private var subHeadline: String {
        if isCorrect {
            // 54.12: pointsDeltaSuffix already carries the correct sign (+3 / -2 / +0);
            // the old "+ " prefix + trim produced "+ -2 points" on a negative delta.
            return String(localized: "\(pointsDeltaSuffix) points", comment: "Result subheadline on a correct answer: points delta")
        }
        return String(localized: "still worth the try", comment: "Result subheadline on an incorrect answer")
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
        // #82 item 2 (decision 7): a skip is not a failure — gentle tick that
        // confirms the voice command landed, no punishing error buzz. The
        // visual stays the plain Result screen (founder: no skip banner).
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
