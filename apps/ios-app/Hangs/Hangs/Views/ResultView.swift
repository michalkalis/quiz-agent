//
//  ResultView.swift
//  Hangs
//
//  Pencil Result screen (correct + incorrect variants). Cream bg, editorial
//  headline, answer comparison card, streak + points stat row, and a footer
//  CTA. Rating / flag / explanation / source link / auto-advance / pause
//  behaviours from the original are preserved.
//

import SwiftUI

struct ResultView: View {
    @ObservedObject var viewModel: QuizViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showEvaluation = false
    @State private var showSourceWebView = false
    @State private var questionRating: Int = 0
    @State private var questionFlagged = false

    var body: some View {
        ZStack {
            Theme.Hangs.Colors.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                HangsQuizNav(
                    onClose: { viewModel.resetToHome() },
                    counterText: counterString
                )
                HangsProgressBar(progress: progressFraction)

                heroBlock

                if showEvaluation, viewModel.resultEvaluation != nil {
                    answerCard
                        .padding(.horizontal, 24)
                        .padding(.top, 8)

                    statsRow
                        .padding(.horizontal, 24)
                        .padding(.top, 12)

                    extrasScroll
                }

                Spacer(minLength: 8)

                countdownBar
                footerBar
            }
        }
        .interactiveMinimize(isMinimized: $viewModel.isMinimized, canMinimize: viewModel.canMinimize)
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
        VStack(alignment: .leading, spacing: 10) {
            HangsResultBanner(kind: isCorrect ? .correct : .incorrect)
            Text(isCorrect ? "NAILED\nIT." : "CLOSE—\nBUT NO.")
                .font(isCorrect ? .hangsDisplayLG : .hangsDisplay(58))
                .tracking(-2)
                .lineSpacing(-8)
                .foregroundColor(Theme.Hangs.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(subHeadline)
                .font(.hangsBody(14, weight: .medium))
                .foregroundColor(Theme.Hangs.Colors.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.top, 20)
        .padding(.bottom, 4)
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
                    secondaryValue: evaluation.correctAnswer,
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
                    labelColor: Theme.Hangs.Colors.blue,
                    valueColor: Theme.Hangs.Colors.blue,
                    suffix: "+1",
                    inlineSuffix: true
                )
                HangsStatBox(
                    label: "points",
                    value: formattedScore,
                    labelColor: Theme.Hangs.Colors.pink,
                    valueColor: Theme.Hangs.Colors.pink,
                    suffix: pointsDeltaSuffix,
                    inlineSuffix: true
                )
            } else {
                HangsStatBox(
                    label: "streak",
                    value: "0",
                    labelColor: Theme.Hangs.Colors.blue,
                    valueColor: Theme.Hangs.Colors.blue,
                    suffix: "was \(previousStreakForIncorrect)",
                    inlineSuffix: true
                )
                HangsStatBox(
                    label: "points",
                    value: formattedScore,
                    labelColor: Theme.Hangs.Colors.pink,
                    valueColor: Theme.Hangs.Colors.pink,
                    suffix: "+0",
                    inlineSuffix: true
                )
            }
        }
    }

    // MARK: - Extras (explanation / source / rating / flag)

    private var extrasScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let explanation = viewModel.resultEvaluation?.explanation
                    ?? viewModel.resultQuestion?.explanation,
                   !explanation.isEmpty {
                    Text(explanation)
                        .font(.hangsBody(14))
                        .foregroundColor(Theme.Hangs.Colors.muted)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if viewModel.resultQuestion?.sourceUrl != nil {
                    HangsGhostButton(
                        title: "View source",
                        icon: "book.closed",
                        color: Theme.Hangs.Colors.blue
                    ) {
                        showSourceWebView = true
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    ratingRow
                    Spacer()
                    flagButton
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 8)
        }
        .frame(maxHeight: 180)
    }

    private var ratingRow: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    questionRating = star
                    viewModel.rateQuestion(star)
                } label: {
                    Image(systemName: star <= questionRating ? "star.fill" : "star")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(
                            star <= questionRating
                                ? Theme.Hangs.Colors.pink
                                : Theme.Hangs.Colors.mutedFaint
                        )
                        .frame(minWidth: 32, minHeight: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(star) star\(star == 1 ? "" : "s")")
                .accessibilityIdentifier("result.ratingStar.\(star)")
            }
        }
    }

    private var flagButton: some View {
        HangsGhostButton(
            title: questionFlagged ? "Reported" : "Report a problem",
            icon: questionFlagged ? "flag.fill" : "flag",
            color: questionFlagged ? Theme.Hangs.Colors.pink : Theme.Hangs.Colors.muted
        ) {
            guard !questionFlagged else { return }
            questionFlagged = true
            viewModel.flagQuestion(reason: "User reported incorrect answer")
        }
        .fixedSize()
        .accessibilityIdentifier("result.flagQuestion")
    }

    // MARK: - Countdown

    @ViewBuilder
    private var countdownBar: some View {
        if viewModel.autoAdvanceEnabled
            && !viewModel.currentQuestionPaused
            && viewModel.autoAdvanceCountdown > 0 {
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
            }

            if viewModel.currentQuestionPaused {
                HangsGhostButton(
                    title: "Resume auto-advance",
                    icon: "play.fill",
                    color: Theme.Hangs.Colors.muted
                ) {
                    viewModel.continueToNext()
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
    }

    // MARK: - Derived

    private var isCorrect: Bool {
        viewModel.resultEvaluation?.isCorrect ?? false
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
