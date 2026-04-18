//
//  ResultView.swift
//  CarQuiz
//
//  Hangs redesign result screen — green/red verdict cards, answer comparison, source/explanation.
//

import SwiftUI

struct ResultView: View {
    @ObservedObject var viewModel: QuizViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showEvaluation = false
    @State private var showQuitConfirmation = false
    @State private var showSourceWebView = false
    @State private var questionRating: Int = 0
    @State private var questionFlagged = false

    var body: some View {
        VStack(spacing: 0) {
            HangsStatusBar(
                leading: "// RESULT.EVAL",
                trailing: "STATUS: \(resultStatusText)",
                leadingColor: Theme.Hangs.Colors.accent,
                trailingDotColor: resultDotColor
            )
            HangsDivider()

            headerTiles

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let evaluation = viewModel.resultEvaluation, showEvaluation {
                        verdictCard(evaluation: evaluation)
                        answerComparison(evaluation: evaluation)

                        if let explanation = evaluation.explanation ?? viewModel.resultQuestion?.explanation {
                            explanationBlock(text: explanation)
                        }

                        if viewModel.resultQuestion?.sourceExcerpt != nil,
                           viewModel.resultQuestion?.sourceUrl != nil {
                            viewSourceButton
                        }

                        if let model = viewModel.currentQuestion?.generatedBy {
                            Text(model)
                                .font(.system(size: 9, weight: .regular, design: .monospaced))
                                .foregroundColor(Theme.Hangs.Colors.textTertiary)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }

                        HStack {
                            ratingRow
                            Spacer()
                            flagButton
                        }
                    } else {
                        ProgressView()
                            .tint(Theme.Hangs.Colors.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }

            if showEvaluation {
                nextCountdown
            }

            bottomBar

            HangsFooterBar(leading: "◢ REG.MARK.04", trailing: footerStatus)
        }
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .interactiveMinimize(isMinimized: $viewModel.isMinimized, canMinimize: viewModel.canMinimize)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: showEvaluation)
        .sensoryFeedback(resultHaptic, trigger: showEvaluation)
        .onAppear { showEvaluation = true }
        .confirmationDialog(
            "End Quiz?",
            isPresented: $showQuitConfirmation,
            titleVisibility: .visible
        ) {
            Button("End Quiz", role: .destructive) { Task { await viewModel.endQuiz() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to quit? Your progress will be saved, but the current session will end.")
        }
        .sheet(isPresented: $showSourceWebView) {
            if let sourceUrl = viewModel.resultQuestion?.sourceUrl {
                SourceWebView(url: sourceUrl, isPresented: $showSourceWebView)
            }
        }
    }

    // MARK: - Header tiles

    private var headerTiles: some View {
        HStack(spacing: 8) {
            ResultView.tile(label: "QUESTION", value: progressText)
            ResultView.tile(label: "SCORE", value: String(format: "%.1f", viewModel.score), valueColor: Theme.Hangs.Colors.infoAccent)
            streakPill
            Spacer()
            closeButton
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private static func tile(label: String, value: String, valueColor: Color = Theme.Hangs.Colors.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .foregroundColor(Theme.Hangs.Colors.textTertiary)
                .tracking(1.5)
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(valueColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.Hangs.Colors.bgCard)
        .overlay(Rectangle().stroke(Theme.Hangs.Colors.divider, lineWidth: 1))
    }

    private var streakPill: some View {
        HStack(spacing: 5) {
            Image(systemName: "flame.fill")
                .font(.system(size: 10, weight: .bold))
            Text("\(viewModel.quizStats.currentStreak) STREAK")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.5)
        }
        .foregroundColor(Theme.Hangs.Colors.bg)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.Hangs.Colors.infoAccent)
    }

    private var closeButton: some View {
        Button { showQuitConfirmation = true } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(Theme.Hangs.Colors.textSecondary)
                .frame(width: 36, height: 36)
                .overlay(Rectangle().stroke(Theme.Hangs.Colors.divider, lineWidth: 1))
        }
        .accessibilityLabel("End quiz")
        .accessibilityIdentifier("result.endQuiz")
    }

    private var progressText: String {
        let total = viewModel.currentSession?.maxQuestions ?? 10
        return String(format: "%02d / %02d", viewModel.questionsAnswered, total)
    }

    // MARK: - Verdict card

    @ViewBuilder
    private func verdictCard(evaluation: Evaluation) -> some View {
        if evaluation.isCorrect {
            verdictCardCorrect(evaluation: evaluation)
        } else {
            verdictCardIncorrect(evaluation: evaluation)
        }
    }

    private func verdictCardCorrect(evaluation: Evaluation) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("◢ CORRECT")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(2)
                Rectangle().fill(Color(white: 0.1).opacity(0.3)).frame(height: 1)
                Text("EVAL.PASS")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
            }
            .foregroundColor(Color(white: 0.1))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Theme.Hangs.Colors.success)

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("[ VERDICT ]")
                        .font(.hangsMonoLabel)
                        .foregroundColor(Theme.Hangs.Colors.success)
                        .tracking(2)
                    Text("CORRECT")
                        .font(.system(size: 38, weight: .black))
                        .tracking(-0.5)
                        .foregroundColor(Theme.Hangs.Colors.textPrimary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("POINTS")
                        .font(.hangsMonoLabel)
                        .foregroundColor(Theme.Hangs.Colors.success)
                        .tracking(1.5)
                    Text(String(format: "+%.1f", evaluation.points))
                        .font(.system(size: 38, weight: .heavy, design: .monospaced))
                        .foregroundColor(Theme.Hangs.Colors.success)
                }
            }
            .padding(20)
        }
        .background(Color(hex: "#0F2A1A"))
        .overlay(Rectangle().stroke(Theme.Hangs.Colors.success, lineWidth: 1.5))
    }

    private func verdictCardIncorrect(evaluation: Evaluation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(Theme.Hangs.Colors.error).frame(width: 6, height: 6)
                Text("// RESULT_ANALYSIS")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(Theme.Hangs.Colors.error)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("ANSWER")
                    .font(.system(size: 50, weight: .black))
                    .tracking(-0.5)
                    .foregroundColor(Theme.Hangs.Colors.textPrimary)
                Text("INCORRECT!")
                    .font(.system(size: 50, weight: .black))
                    .tracking(-0.5)
                    .foregroundColor(Theme.Hangs.Colors.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
                    .background(Theme.Hangs.Colors.error)
            }
        }
    }

    // MARK: - Answer comparison

    private func answerComparison(evaluation: Evaluation) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            comparisonRow(label: "YOUR_ANSWER", value: evaluation.userAnswer, labelColor: Theme.Hangs.Colors.textTertiary, valueColor: Theme.Hangs.Colors.textPrimary)
            Rectangle().fill(Theme.Hangs.Colors.divider).frame(height: 1)
            comparisonRow(label: "CORRECT_ANSWER", value: evaluation.correctAnswer, labelColor: Theme.Hangs.Colors.success, valueColor: Theme.Hangs.Colors.success)
        }
        .background(Theme.Hangs.Colors.bgCard)
        .overlay(Rectangle().stroke(evaluation.isCorrect ? Theme.Hangs.Colors.divider : Theme.Hangs.Colors.error, lineWidth: 1))
    }

    private func comparisonRow(label: String, value: String, labelColor: Color, valueColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.hangsMonoLabel)
                .foregroundColor(labelColor)
                .tracking(1.8)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(valueColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Explanation

    private func explanationBlock(text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("◢")
                    .font(.hangsMonoLabel)
                    .foregroundColor(Theme.Hangs.Colors.accent)
                Text("[ EXPLANATION ]")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.Hangs.Colors.accent)
                    .tracking(2)
                Rectangle().fill(Theme.Hangs.Colors.divider).frame(height: 1)
            }
            Text(text)
                .font(.system(size: 14))
                .foregroundColor(Theme.Hangs.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - View source

    private var viewSourceButton: some View {
        Button { showSourceWebView = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 12, weight: .semibold))
                Text("VIEW SOURCE")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .tracking(2)
            }
            .foregroundColor(Theme.Hangs.Colors.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .overlay(Rectangle().stroke(Theme.Hangs.Colors.divider, lineWidth: 1))
        }
        .accessibilityLabel("View source")
    }

    // MARK: - Rating + flag

    private var ratingRow: some View {
        HStack(spacing: 0) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    questionRating = star
                    viewModel.rateQuestion(star)
                } label: {
                    Image(systemName: star <= questionRating ? "star.fill" : "star")
                        .font(.system(size: 14))
                        .foregroundColor(star <= questionRating ? Theme.Hangs.Colors.warning : Theme.Hangs.Colors.textTertiary)
                        .frame(minWidth: 36, minHeight: 36)
                }
                .accessibilityLabel("\(star) star\(star == 1 ? "" : "s")")
                .accessibilityIdentifier("result.ratingStar.\(star)")
            }
        }
    }

    private var flagButton: some View {
        Button {
            questionFlagged = true
            viewModel.flagQuestion(reason: "User reported incorrect answer")
        } label: {
            Image(systemName: questionFlagged ? "flag.fill" : "flag")
                .font(.system(size: 14))
                .foregroundColor(questionFlagged ? Theme.Hangs.Colors.error : Theme.Hangs.Colors.textTertiary)
                .frame(minWidth: 36, minHeight: 36)
        }
        .disabled(questionFlagged)
        .accessibilityLabel(questionFlagged ? "Reported" : "Report question")
        .accessibilityIdentifier("result.flagQuestion")
    }

    // MARK: - Next countdown

    @ViewBuilder
    private var nextCountdown: some View {
        if viewModel.autoAdvanceEnabled && !viewModel.currentQuestionPaused && viewModel.autoAdvanceCountdown > 0 {
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    Text("◢ NEXT IN")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.Hangs.Colors.accent)
                        .tracking(2)
                    Rectangle().fill(Theme.Hangs.Colors.divider).frame(height: 1)
                    Text(String(format: "%02ds", viewModel.autoAdvanceCountdown))
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.Hangs.Colors.textPrimary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .overlay(Rectangle().stroke(Theme.Hangs.Colors.infoAccent, lineWidth: 1))

                // Thin progress bar
                GeometryReader { geo in
                    let total = max(1, viewModel.settings.autoAdvanceDelay)
                    let fraction = CGFloat(viewModel.autoAdvanceCountdown) / CGFloat(total)
                    Rectangle()
                        .fill(Theme.Hangs.Colors.infoAccent)
                        .frame(width: geo.size.width * fraction, height: 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.Hangs.Colors.bgCard)
                }
                .frame(height: 3)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HangsPrimaryButton(
                title: continueTitle,
                icon: "arrow.right"
            ) {
                viewModel.continueToNext()
            }
            .accessibilityIdentifier("result.continue")

            if viewModel.autoAdvanceEnabled && !viewModel.currentQuestionPaused {
                Button("Stay Here") { viewModel.pauseQuiz() }
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.Hangs.Colors.textSecondary)
                    .accessibilityIdentifier("result.stayHere")
            } else if viewModel.currentQuestionPaused {
                Text("PAUSED")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.Hangs.Colors.textSecondary)
                    .tracking(2)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    private var continueTitle: String {
        if viewModel.autoAdvanceEnabled && !viewModel.currentQuestionPaused && viewModel.autoAdvanceCountdown > 0 {
            return "CONTINUE (\(viewModel.autoAdvanceCountdown)s)"
        }
        return "CONTINUE"
    }

    // MARK: - Derived

    private var resultHaptic: SensoryFeedback {
        guard let evaluation = viewModel.resultEvaluation else { return .impact }
        switch evaluation.result {
        case .correct: return .success
        case .incorrect, .skipped: return .error
        case .partiallyCorrect, .partiallyIncorrect: return .warning
        }
    }

    private var resultStatusText: String {
        guard let eval = viewModel.resultEvaluation else { return "PENDING" }
        return eval.isCorrect ? "OK" : "FAIL"
    }

    private var resultDotColor: Color {
        guard let eval = viewModel.resultEvaluation else { return Theme.Hangs.Colors.textSecondary }
        return eval.isCorrect ? Theme.Hangs.Colors.success : Theme.Hangs.Colors.error
    }

    private var footerStatus: String {
        guard let eval = viewModel.resultEvaluation else { return "Q.\(viewModel.questionsAnswered)" }
        let sign = eval.points >= 0 ? "+" : ""
        return String(format: "Q.%03d  ●  %@%.1f PTS", viewModel.questionsAnswered, sign, eval.points)
    }
}

#if DEBUG
#Preview {
    ResultView(viewModel: QuizViewModel.previewWithEvaluation)
}
#endif
