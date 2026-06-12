//
//  CompletionViewInspectorTests.swift
//  HangsTests
//
//  #52 task 52.12 — Quiz-Complete view bound to QuizCompleteSummary (NPlqf frame).
//
//  Why these tests matter:
//  - The view's `summary` property must derive from QuizCompleteSummary.from(...)
//    rather than inline viewModel fields; a drift there would show stale values.
//  - The breakdown card must show Accuracy (not the legacy "Avg points") and use
//    successText (green) for Correct and .error (red) for Incorrect — matching NPlqf.
//  - Structural: "Accuracy" row label must be present in the tree; "Avg points" must not.
//

import Foundation
@testable import Hangs
import Testing
import ViewInspector

// MARK: - Summary binding

@MainActor
@Suite("CompletionView — QuizCompleteSummary binding")
struct CompletionViewSummaryTests {
    private func makeViewModel(
        score: Double, answered: Int, correct: Int, incorrect: Int
    ) -> QuizViewModel {
        let vm = QuizViewModel(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        vm.score = score
        vm.questionsAnswered = answered
        vm.sessionCorrectCount = correct
        vm.sessionIncorrectCount = incorrect
        vm.quizStats = QuizStats(
            currentStreak: 0,
            bestStreak: 3,
            totalCorrect: correct,
            totalAnswered: answered,
            totalQuizzes: 1
        )
        vm.quizState = .finished
        return vm
    }

    @Test("summary counts come from per-session tallies, not the score (54.13)")
    func summaryCountsFromTallies() {
        // Fractional score (partial credit): counts must NOT be derived from it.
        let vm = makeViewModel(score: 7.5, answered: 10, correct: 7, incorrect: 2)
        let view = CompletionView(viewModel: vm)
        #expect(view.summary.correctCount == 7)
        #expect(view.summary.incorrectCount == 2)
        #expect(view.summary.displayScore == "7.5")
    }

    @Test("summary.sessionAccuracyPercent = 70 for 7/10")
    func summaryAccuracy() {
        let vm = makeViewModel(score: 7, answered: 10, correct: 7, incorrect: 3)
        let view = CompletionView(viewModel: vm)
        #expect(abs(view.summary.sessionAccuracyPercent - 70.0) < 0.01)
    }

    @Test("summary.totalQuestions uses settings.numberOfQuestions fallback when session is nil")
    func summaryTotalQuestionsFromSettings() {
        let vm = makeViewModel(score: 5, answered: 8, correct: 5, incorrect: 3)
        vm.settings.numberOfQuestions = 10
        let view = CompletionView(viewModel: vm)
        // currentSession is nil → falls back to settings.numberOfQuestions
        #expect(view.summary.totalQuestions == 10)
    }
}

// MARK: - Structural: Accuracy row in view tree

@MainActor
@Suite("CompletionView — breakdown card structure (NPlqf)")
struct CompletionViewBreakdownTests {
    @Test("'Accuracy' label renders in breakdown card")
    func accuracyRowPresent() async throws {
        let vm: QuizViewModel = {
            let v = QuizViewModel(
                networkService: MockNetworkService(),
                audioService: MockAudioService(),
                persistenceStore: MockPersistenceStore()
            )
            v.score = 8
            v.questionsAnswered = 10
            v.quizState = .finished
            return v
        }()
        let view = CompletionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "Accuracy")
            }
        }
    }

    @Test("'Avg points' label does NOT render (replaced by Accuracy)")
    func avgPointsRowAbsent() async throws {
        let vm: QuizViewModel = {
            let v = QuizViewModel(
                networkService: MockNetworkService(),
                audioService: MockAudioService(),
                persistenceStore: MockPersistenceStore()
            )
            v.score = 8
            v.questionsAnswered = 10
            v.quizState = .finished
            return v
        }()
        let view = CompletionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) {
                try tree.find(text: "Avg points")
            }
        }
    }
}
