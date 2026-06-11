//
//  QuizCompleteSummaryTests.swift
//  HangsTests
//
//  #52 task 52.6 — Quiz-Complete aggregation.
//
//  Why these tests matter:
//  - Divide-by-zero: accuracy and avgPoints must be 0.0 (not NaN/inf) when questionsAnswered == 0.
//  - The incorrectCount formula prevents a negative when score somehow exceeds answeredCount.
//  - The maxQuestions fallback keeps the "out of N" label accurate even when the session
//    object has been cleared before CompletionView renders.
//  - The bestStreak comes from QuizStats (updated throughout the quiz) so that the
//    end-of-session streak reflects the highest run achieved, even if the final answer broke it.
//

@testable import Hangs
import Testing

@Suite("QuizCompleteSummary aggregation")
struct QuizCompleteSummaryTests {
    // MARK: - Happy-path

    @Test("perfect quiz: all correct aggregates cleanly")
    func perfectQuiz() {
        let stats = QuizStats(currentStreak: 5, bestStreak: 5, totalCorrect: 5, totalAnswered: 5, totalQuizzes: 1)
        let summary = QuizCompleteSummary.from(score: 5.0, questionsAnswered: 5, maxQuestions: 5, stats: stats)

        #expect(summary.finalScore == 5.0)
        #expect(summary.correctCount == 5)
        #expect(summary.incorrectCount == 0)
        #expect(summary.totalAnswered == 5)
        #expect(summary.totalQuestions == 5)
        #expect(summary.sessionAccuracyPercent == 100.0)
        #expect(summary.bestStreak == 5)
        #expect(summary.avgPointsPerQuestion == 1.0)
    }

    @Test("mixed results: correct/incorrect/accuracy split")
    func mixedQuiz() {
        let stats = QuizStats(currentStreak: 0, bestStreak: 3, totalCorrect: 3, totalAnswered: 5, totalQuizzes: 1)
        let summary = QuizCompleteSummary.from(score: 3.0, questionsAnswered: 5, maxQuestions: 5, stats: stats)

        #expect(summary.correctCount == 3)
        #expect(summary.incorrectCount == 2)
        #expect(summary.sessionAccuracyPercent == 60.0)
        #expect(summary.bestStreak == 3)
        #expect(abs(summary.avgPointsPerQuestion - 0.6) < 0.001)
    }

    @Test("bestStreak reflects end-of-session high even when final answer broke the streak")
    func bestStreakPreserved() {
        // Last answer was wrong (currentStreak reset to 0), but bestStreak was 4
        let stats = QuizStats(currentStreak: 0, bestStreak: 4, totalCorrect: 4, totalAnswered: 5, totalQuizzes: 1)
        let summary = QuizCompleteSummary.from(score: 4.0, questionsAnswered: 5, maxQuestions: 5, stats: stats)

        #expect(summary.bestStreak == 4)
    }

    // MARK: - Edge cases

    @Test("maxQuestions falls back to questionsAnswered when session is nil")
    func maxQuestionsFallback() {
        let summary = QuizCompleteSummary.from(score: 2.0, questionsAnswered: 4, maxQuestions: nil, stats: .empty)

        #expect(summary.totalQuestions == 4)
    }

    @Test("zero answers: accuracy and avgPoints are 0.0, not NaN or inf")
    func zeroAnswersNoDivisionByZero() {
        let summary = QuizCompleteSummary.from(score: 0.0, questionsAnswered: 0, maxQuestions: 5, stats: .empty)

        #expect(summary.sessionAccuracyPercent == 0.0)
        #expect(summary.avgPointsPerQuestion == 0.0)
        #expect(summary.incorrectCount == 0)
        #expect(!summary.sessionAccuracyPercent.isNaN)
        #expect(!summary.avgPointsPerQuestion.isNaN)
    }

    @Test("incorrectCount clamps to zero — never negative")
    func incorrectCountNeverNegative() {
        // Defensive: score could momentarily exceed answeredCount in edge cases
        let summary = QuizCompleteSummary.from(score: 5.0, questionsAnswered: 3, maxQuestions: 5, stats: .empty)

        #expect(summary.incorrectCount == 0)
    }
}
