//
//  CompletionView.swift
//  Hangs
//
//  Hangs redesign quiz completion — "QUIZ MASTER!" hero, final score card, metric tiles.
//

import SwiftUI

struct CompletionView: View {
    @ObservedObject var viewModel: QuizViewModel

    var body: some View {
        VStack(spacing: 0) {
            HangsStatusBar(
                leading: "// FINAL_RESULTS",
                trailing: "● SESSION_END",
                leadingColor: Theme.Hangs.Colors.infoAccent,
                trailingDotColor: Theme.Hangs.Colors.accent
            )
            HangsDivider()

            HStack {
                Spacer()
                Button { viewModel.resetToHome() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Theme.Hangs.Colors.textPrimary)
                        .frame(width: 36, height: 36)
                        .background(Theme.Hangs.Colors.bgCard)
                        .overlay(Rectangle().stroke(Theme.Hangs.Colors.divider, lineWidth: 1))
                }
                .accessibilityLabel("Close")
                .accessibilityIdentifier("completion.close")
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    heroBlock
                    scoreCard
                    statTiles
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 20)
            }

            actionButtons
            HangsFooterBar(leading: "◢ REG.MARK.05", trailing: "SESSION.END ● OK")
        }
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    // MARK: - Hero

    private var heroBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 60, weight: .black))
                .tracking(-1)
                .foregroundColor(Theme.Hangs.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(accentTitle)
                .font(.system(size: 60, weight: .black))
                .tracking(-1)
                .foregroundColor(Theme.Hangs.Colors.bg)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
                .background(Theme.Hangs.Colors.accent)
        }
    }

    private var title: String {
        if scorePercentage >= 80 { return "QUIZ" }
        if scorePercentage >= 60 { return "WELL" }
        return "NICE"
    }

    private var accentTitle: String {
        if scorePercentage >= 80 { return "MASTER!" }
        if scorePercentage >= 60 { return "DONE!" }
        return "EFFORT!"
    }

    // MARK: - Score card

    private var scoreCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("FINAL_SCORE")
                    .font(.hangsMonoLabel)
                    .foregroundColor(Theme.Hangs.Colors.textSecondary)
                    .tracking(2)
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(String(format: "%.1f", viewModel.score))
                        .font(.system(size: 48, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.Hangs.Colors.textPrimary)
                    Text("/\(maxQuestions)")
                        .font(.system(size: 22, design: .monospaced))
                        .foregroundColor(Theme.Hangs.Colors.textSecondary)
                }
            }
            Rectangle().fill(Theme.Hangs.Colors.divider).frame(height: 1)
            HStack {
                Text("ACCURACY")
                    .font(.hangsMonoLabel)
                    .foregroundColor(Theme.Hangs.Colors.textSecondary)
                    .tracking(2)
                Spacer()
                Text(String(format: "%d%%", Int(scorePercentage)))
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.Hangs.Colors.textPrimary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Theme.Hangs.Colors.bgCard)
        .overlay(Rectangle().stroke(Theme.Hangs.Colors.infoAccent, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Final score: \(Int(viewModel.score)) of \(maxQuestions), \(Int(scorePercentage)) percent accuracy")
        .accessibilityIdentifier("completion.score")
    }

    // MARK: - Stat tiles

    private var statTiles: some View {
        HStack(spacing: 12) {
            statTile(value: "\(Int(viewModel.score))/\(maxQuestions)", label: "CORRECT")
            statTile(value: "\(viewModel.quizStats.bestStreak)", label: "STREAK")
        }
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.Hangs.Colors.textPrimary)
            Text(label)
                .font(.hangsMonoLabel)
                .foregroundColor(Theme.Hangs.Colors.infoAccent)
                .tracking(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .background(Theme.Hangs.Colors.bgCard)
        .overlay(Rectangle().stroke(Theme.Hangs.Colors.divider, lineWidth: 1))
    }

    // MARK: - Actions

    private var actionButtons: some View {
        VStack(spacing: 12) {
            HangsPrimaryButton(title: "PLAY AGAIN", icon: "arrow.clockwise") {
                Task { await viewModel.startNewQuiz() }
            }
            .accessibilityIdentifier("completion.playAgain")

            Button {
                viewModel.resetToHome()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 13, weight: .bold))
                    Text("BACK TO HOME")
                        .font(.system(size: 14, weight: .semibold))
                        .tracking(2)
                }
                .foregroundColor(Theme.Hangs.Colors.infoAccent)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .overlay(Rectangle().stroke(Theme.Hangs.Colors.infoAccent, lineWidth: 1.5))
            }
            .accessibilityIdentifier("completion.backToHome")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    // MARK: - Derived

    private var maxQuestions: Int {
        viewModel.currentSession?.maxQuestions ?? max(viewModel.questionsAnswered, 1)
    }

    private var scorePercentage: Double {
        guard maxQuestions > 0 else { return 0 }
        return (viewModel.score / Double(maxQuestions)) * 100
    }
}

#if DEBUG
#Preview {
    let viewModel: QuizViewModel = {
        let vm = QuizViewModel.previewWithEvaluation
        vm.score = 8.5
        vm.questionsAnswered = 10
        vm.quizState = .finished
        return vm
    }()
    CompletionView(viewModel: viewModel)
}
#endif
