//
//  QuizViewModelStreakTests.swift
//  HangsTests
//
//  #54 tasks 54.11 + 54.13 — per-answer bookkeeping in handleQuizResponse.
//
//  Why these tests matter:
//  - 54.11: ResultView's "streak was X" on an incorrect answer must show the streak
//    that was just broken — not the all-time best (the old proxy). By the time the
//    view renders, quizStats.currentStreak is already 0, so the VM must capture the
//    pre-reset value. bestStreak is deliberately different from currentStreak in the
//    fixture so the old proxy would fail this test.
//  - 54.13: the completion breakdown counts come from per-session evaluation tallies,
//    not from flooring the fractional score. Partials must land in neither bucket so
//    correct + incorrect can never exceed answered.
//

import Foundation
import Testing
@testable import Hangs

/// Minimal QuizResponse carrying an evaluation with the given result.
@MainActor
private func makeResponse(result: Evaluation.EvaluationResult, questionId: String = "q_001") -> QuizResponse {
    QuizResponse(
        success: true,
        message: "Input processed",
        session: Fixtures.makeQuizSession(),
        currentQuestion: nil,
        evaluation: Evaluation(
            userAnswer: "Test",
            result: result,
            points: result == .correct ? 1.0 : (result == .partiallyCorrect ? 0.5 : 0.0),
            correctAnswer: "Expected Answer",
            questionId: questionId,
            explanation: nil
        ),
        feedbackReceived: [],
        audio: nil
    )
}

@Suite("QuizViewModel answer bookkeeping (54.11 / 54.13)")
@MainActor
struct QuizViewModelStreakTests {

    @Test("incorrect answer captures the streak it broke, not the all-time best (54.11)")
    func incorrectAnswerCapturesPriorStreak() async {
        let vm = Fixtures.makeViewModel()
        // bestStreak (7) ≠ currentStreak (3): the old bestStreak proxy would read 7 here.
        vm.quizStats = QuizStats(
            currentStreak: 3, bestStreak: 7,
            totalCorrect: 10, totalAnswered: 12, totalQuizzes: 2
        )
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        vm.quizState = .processing

        await vm.handleQuizResponse(makeResponse(result: .incorrect))

        #expect(vm.streakBeforeLastAnswer == 3)
        #expect(vm.quizStats.currentStreak == 0)
    }

    @Test("session tallies: partials and skips land in neither bucket (54.13)")
    func sessionTalliesPerResult() async {
        let vm = Fixtures.makeViewModel()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")

        for result in [Evaluation.EvaluationResult.correct, .partiallyCorrect, .incorrect, .skipped] {
            vm.quizState = .processing
            await vm.handleQuizResponse(makeResponse(result: result))
        }

        #expect(vm.sessionCorrectCount == 1)
        #expect(vm.sessionIncorrectCount == 1)
    }

    /// WHY (adversarial audit 2026-07-30): a response whose submission was already
    /// superseded — e.g. a spoken "stop" during an MCQ evaluation transitions back
    /// to .askingQuestion but cannot cancel the inline request — used to commit the
    /// score, the persisted stats, the tallies and a recap row and only THEN have
    /// its .showingResult transition rejected. The driver was left on the same
    /// question with an inflated score and a phantom recap row. Half-committed
    /// state is worse than a dropped response: nothing may be recorded unless the
    /// result can actually be shown.
    @Test("a response arriving after the submission was superseded mutates nothing")
    func rejectedTransitionCommitsNoState() async {
        let vm = Fixtures.makeViewModel()
        vm.quizStats = QuizStats(
            currentStreak: 3, bestStreak: 7,
            totalCorrect: 10, totalAnswered: 12, totalQuizzes: 2
        )
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        // The submission was cancelled: the state machine is back on the question,
        // from which .showingResult is not a legal transition.
        vm.quizState = .askingQuestion

        await vm.handleQuizResponse(makeResponse(result: .correct))

        #expect(vm.quizState == .askingQuestion)
        #expect(vm.quizStats.currentStreak == 3, "no answer was shown — the streak must not advance")
        #expect(vm.quizStats.totalAnswered == 12)
        #expect(vm.sessionCorrectCount == 0)
        #expect(vm.recapEntries.isEmpty, "a result the driver never saw must not appear in the recap")
        #expect(vm.currentSession?.id == nil, "the superseded response must not replace the session")
    }

    @Test("resetState clears the session tallies for the next quiz (54.13)")
    func resetClearsSessionTallies() async {
        let vm = Fixtures.makeViewModel()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        vm.quizState = .processing
        await vm.handleQuizResponse(makeResponse(result: .correct))
        #expect(vm.sessionCorrectCount == 1)

        vm.resetToHome()

        #expect(vm.sessionCorrectCount == 0)
        #expect(vm.sessionIncorrectCount == 0)
    }
}
