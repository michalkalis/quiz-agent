//
//  ResultView.swift
//  Hangs
//
//  Pencil Result screen — correct (X4o4l) and incorrect (31AzE) variants.
//  bg-page background, editorial Anton headline, answer comparison card,
//  streak + score stat boxes, and a footer CTA. Auto-advance countdown bar
//  and source web-view sheet preserved from original design.
//

import SwiftUI

struct ResultView: View {
    @ObservedObject var viewModel: QuizViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showEvaluation = false
    @State private var showSourceWebView = false

    var body: some View {
        ZStack {
            Theme.Hangs.Colors.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                HangsQuizNav(
                    onClose: { viewModel.resetToHome() },
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

                countdownBar
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
            Text(isCorrect ? "NAILED\nIT." : "MISSED\nIT.")
                .font(.hangsDisplay(52))
                .tracking(-2)
                .lineSpacing(-6)
                .foregroundColor(Theme.Hangs.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
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
            if let url = viewModel.currentQuestionAudioUrl {
                Task { await viewModel.playQuestionAudio(from: url) }
            }
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

    private var statsRow: some View {
        HStack(spacing: 12) {
            if isCorrect {
                HangsStatBox(
                    label: "streak",
                    value: "\(viewModel.quizStats.currentStreak)",
                    labelColor: Theme.Hangs.Colors.pink,
                    valueColor: Theme.Hangs.Colors.ink,
                    suffix: "+1",
                    inlineSuffix: true,
                    compact: true
                )
                HangsStatBox(
                    label: "score",
                    value: formattedScore,
                    labelColor: Theme.Hangs.Colors.pink,
                    valueColor: Theme.Hangs.Colors.ink,
                    suffix: pointsDeltaSuffix,
                    inlineSuffix: true,
                    compact: true
                )
            } else {
                HangsStatBox(
                    label: "streak",
                    value: "0",
                    labelColor: Theme.Hangs.Colors.pink,
                    valueColor: Theme.Hangs.Colors.ink,
                    suffix: "was \(previousStreakForIncorrect)",
                    inlineSuffix: false,
                    compact: true
                )
                HangsStatBox(
                    label: "score",
                    value: formattedScore,
                    labelColor: Theme.Hangs.Colors.pink,
                    valueColor: Theme.Hangs.Colors.ink,
                    suffix: "+0",
                    inlineSuffix: true,
                    compact: true
                )
            }
        }
    }

    // MARK: - Countdown

    @ViewBuilder
    private var countdownBar: some View {
        if viewModel.autoAdvanceEnabled
            && !viewModel.currentQuestionPaused
            && viewModel.autoAdvanceCountdown > 0
        {
            VStack(spacing: 6) {
                HStack {
                    Text("Next in \(viewModel.autoAdvanceCountdown)s")
                        .font(.hangsMono(11, weight: .medium))
                        .tracking(1.5)
                        .foregroundColor(Theme.Hangs.Colors.muted)
                    Spacer()
                    Button("Stay here") { viewModel.pauseQuiz() }
                        .font(.hangsBody(13, weight: .semibold))
                        .foregroundColor(Theme.Hangs.Colors.blue)
                        .accessibilityIdentifier("result.stayHere")
                }
                GeometryReader { geo in
                    let total = max(1, viewModel.settings.autoAdvanceDelay)
                    let fraction = CGFloat(viewModel.autoAdvanceCountdown) / CGFloat(total)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.Hangs.Colors.mutedBorder)
                        Capsule()
                            .fill(Theme.Hangs.Colors.pink)
                            .frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: 3)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 10)
        }
    }

    // MARK: - Footer

    private var footerBar: some View {
        VStack(spacing: 10) {
            HangsPrimaryButton(
                title: "Next question",
                icon: nil,
                trailingIcon: "arrow.right",
                height: 64
            ) {
                viewModel.continueToNext()
            }
            .accessibilityIdentifier("result.continue")

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

            if !isCorrect {
                HangsGhostButton(
                    title: "Try this question again",
                    icon: "arrow.counterclockwise",
                    color: Theme.Hangs.Colors.blue
                ) {
                    viewModel.continueToNext()
                }
                .accessibilityIdentifier("result.tryAgain")
            }

            if viewModel.currentQuestionPaused {
                HangsGhostButton(
                    title: "Resume auto-advance",
                    icon: "play.fill",
                    color: Theme.Hangs.Colors.muted
                ) {
                    viewModel.continueToNext()
                }
                .accessibilityIdentifier("result-resume-auto-advance-button")
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
    }

    // MARK: - Derived

    private func pauseAutoAdvanceIfActive() {
        guard viewModel.autoAdvanceEnabled,
              !viewModel.currentQuestionPaused,
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
        viewModel.currentSession?.maxQuestions ?? 10
    }

    private var counterString: String {
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

    /// On an incorrect answer we already reset `currentStreak` to 0 — best proxy
    /// for "what the streak was" is the all-time best (or 0 when no runs yet).
    private var previousStreakForIncorrect: Int {
        max(viewModel.quizStats.bestStreak, 0)
    }

    private var subHeadline: String {
        if isCorrect {
            return "+ \(pointsDeltaSuffix.trimmingCharacters(in: CharacterSet(charactersIn: "+"))) points · streak now \(viewModel.quizStats.currentStreak)"
        }
        return "streak reset · still worth the try"
    }

    private var resultHaptic: SensoryFeedback {
        guard let evaluation = viewModel.resultEvaluation else { return .impact }
        switch evaluation.result {
        case .correct: return .success
        case .incorrect, .skipped: return .error
        case .partiallyCorrect, .partiallyIncorrect: return .warning
        }
    }
}

#if DEBUG
    #Preview {
        ResultView(viewModel: QuizViewModel.previewWithEvaluation)
    }
#endif
