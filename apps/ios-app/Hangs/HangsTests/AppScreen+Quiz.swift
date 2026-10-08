//
//  AppScreen+Quiz.swift
//  HangsTests
//
//  #194 A2: builders for the quiz-adjacent screens — Completion, the set recap,
//  the answer confirmation sheet and the error screen. See AppScreenSnapshotTests.
//

import Clocks
import Foundation
@testable import Hangs
import SwiftUI

extension AppScreen {
    func make() async -> AnyView {
        switch self {
        case .completion: Self.completion(remaining: 18)
        // Four left is inside the upsell threshold (`upsellRemaining` <= 5).
        case .completionUpsell: Self.completion(remaining: 4)
        case .setRecap: await Self.setRecap()
        case .confirmTranscribing: Self.confirmation(isProcessing: true, transcript: "", onCancel: {})
        case .confirmTranscript: Self.confirmation(isProcessing: false, transcript: "Paris, I think. Or maybe Lyon.")
        case .errorRetry: Self.error(.from(URLError(.notConnectedToInternet)))
        case .errorGoHome: Self.error(.historyAtCapacity)
        case .errorDismiss: Self.error(.from(CancellationError()))
        default: await makeFlow()
        }
    }

    // MARK: Completion

    private static func completion(remaining: Int) -> AnyView {
        let vm = Fixtures.makeViewModel(clock: AnyClock(TestClock()))
        vm.currentSession = Fixtures.session(score: 7.5, answered: 10)
        vm.sessionCorrectCount = 7
        vm.sessionIncorrectCount = 3
        vm.quizStats = QuizStats(currentStreak: 2, bestStreak: 5, totalCorrect: 7, totalAnswered: 10, totalQuizzes: 3)
        vm.usageInfo = UsageInfo(
            userId: "snapshot-subject",
            isPremium: false,
            questionsUsed: 30 - remaining,
            questionsLimit: 30,
            remaining: remaining,
            resetsAt: "2030-01-01T00:00:00Z",
            subscriptionStatus: "none",
            creditBalance: 0
        )
        vm.quizState = .finished
        return AnyView(CompletionView(viewModel: vm))
    }

    // MARK: Set recap

    /// The ledger is filled through the real capture path (`handleQuizResponse`)
    /// because `recapEntries` is `private(set)`: one correct, one wrong, one skipped.
    private static func setRecap() async -> AnyView {
        let vm = Fixtures.makeViewModel(clock: AnyClock(TestClock()))
        vm.settings.answerRevealMode = .endOfSet
        vm.settings.autoRecordEnabled = false // the recap must not narrate in a snapshot
        vm.currentSession = Fixtures.makeQuizSession()

        let rounds: [(number: Int, text: String, answer: String, result: Evaluation.EvaluationResult, said: String)] = [
            (1, "What is the capital of France?", "Paris", .correct, "Paris"),
            (2, "Which river flows through Budapest?", "Danube", .incorrect, "The Vltava"),
            (3, "How many strings does a standard violin have?", "Four", .skipped, ""),
        ]
        for round in rounds {
            let question = recapQuestion(round.number, round.text, answer: round.answer)
            vm.currentQuestion = question
            vm.quizState = round.result == .skipped ? .skipping : .processing
            await vm.handleQuizResponse(QuizResponse(
                success: true,
                message: "ok",
                session: Fixtures.makeQuizSession(),
                currentQuestion: Fixtures.makeQuestion(id: "q_next"),
                evaluation: Evaluation(
                    userAnswer: round.said,
                    result: round.result,
                    points: round.result == .correct ? 1 : 0,
                    correctAnswer: round.answer,
                    questionId: question.id,
                    explanation: question.explanation,
                    headlineAnswer: nil
                ),
                feedbackReceived: [],
                audio: nil
            ))
            // The deferred reveal advance would walk on to the next question.
            vm.taskBag.cancel(.deferredAdvance)
        }
        vm.quizState = .finished
        vm.taskBag.cancelAll()
        return AnyView(SetRecapView(viewModel: vm))
    }

    private static func recapQuestion(_ number: Int, _ text: String, answer: String) -> Question {
        Question(
            id: "recap_\(number)",
            question: text,
            type: .text,
            possibleAnswers: nil,
            difficulty: "easy",
            topic: "General",
            category: "geography-world",
            sourceUrl: "https://en.wikipedia.org/wiki/Question_\(number)",
            sourceExcerpt: answer,
            mediaUrl: nil,
            imageSubtype: nil,
            explanation: "\(answer) is the answer to question \(number); it is easy to confuse with its neighbours.",
            generatedBy: "snapshot"
        )
    }

    // MARK: Answer confirmation

    private static func confirmation(
        isProcessing: Bool,
        transcript: String,
        onCancel: (() -> Void)? = nil
    ) -> AnyView {
        AnyView(AnswerConfirmationView(
            isProcessing: isProcessing,
            transcribedAnswer: .constant(transcript),
            autoConfirmCountdown: 4,
            autoConfirmEnabled: true,
            autoConfirmTotal: 5,
            onConfirm: {},
            onReRecord: {},
            onCancel: onCancel
        ))
    }

    // MARK: Error

    private static func error(_ model: AppErrorModel) -> AnyView {
        AnyView(ErrorView(viewModel: Fixtures.makeViewModel(clock: AnyClock(TestClock())), model: model))
    }
}
