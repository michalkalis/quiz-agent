//
//  CompletionView.swift
//  Hangs
//
//  Quiz-Complete route (per-question reveal). #194 C5: it draws the merged
//  end-of-round screen (`RoundCompleteView`: score + answer list); the
//  summary and the upsell rule stay here, where the tests pin them.
//  Display data sourced from QuizCompleteSummary (52.6); actions via viewModel.
//

import SwiftUI

struct CompletionView: View {
    @ObservedObject var viewModel: QuizViewModel

    var body: some View {
        // #194 C5: the per-question route draws the merged end-of-round screen.
        RoundCompleteView(
            viewModel: viewModel,
            route: .score,
            summary: summary,
            upsellRemaining: upsellRemaining
        )
        .task { await viewModel.refreshUsage() }
    }

    /// #94 third paywall touchpoint: soft upsell at the highest-intent moment
    /// when the free quota is nearly exhausted. Hidden for premium users and
    /// whenever quota data is missing. Internal so tests pin the rule directly.
    var upsellRemaining: Int? {
        guard let usage = viewModel.usageInfo,
              !usage.isPremium,
              let remaining = usage.remaining,
              remaining <= 5 else { return nil }
        return remaining
    }

    var summary: QuizCompleteSummary {
        QuizCompleteSummary.from(
            score: viewModel.score,
            questionsAnswered: viewModel.questionsAnswered,
            correctCount: viewModel.sessionCorrectCount,
            incorrectCount: viewModel.sessionIncorrectCount,
            maxQuestions: viewModel.currentSession?.maxQuestions
                ?? viewModel.settings.numberOfQuestions,
            stats: viewModel.quizStats
        )
    }
}

#if DEBUG
    #Preview {
        let viewModel: QuizViewModel = {
            let vm = QuizViewModel.previewWithEvaluation
            vm.currentSession = QuizSession.preview(score: 8.5, answered: 10)
            vm.quizState = .finished
            return vm
        }()
        return CompletionView(viewModel: viewModel)
    }
#endif
