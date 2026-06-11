//
//  QuizCompleteSummary.swift
//  Hangs
//
//  Aggregated end-of-session summary for the Quiz-Complete screen (NPlqf).
//  Pure value type — no ViewModel dependency, fully testable in isolation.
//

import Foundation

/// End-of-session summary computed from QuizViewModel state when phase = .finished.
/// 52.12 binds CompletionView to this struct instead of deriving values inline in the view.
struct QuizCompleteSummary: Equatable, Sendable {
    let finalScore: Double
    let correctCount: Int
    let incorrectCount: Int
    let totalAnswered: Int
    let totalQuestions: Int
    let sessionAccuracyPercent: Double // this-quiz accuracy (not cumulative)
    let bestStreak: Int // session end best streak from QuizStats
    let avgPointsPerQuestion: Double

    /// Aggregate from the primitive values available on QuizViewModel at .finished state.
    /// - Parameters:
    ///   - score: `QuizViewModel.score` (1 point per correct answer)
    ///   - questionsAnswered: `QuizViewModel.questionsAnswered`
    ///   - maxQuestions: `QuizViewModel.currentSession?.maxQuestions` — falls back to `questionsAnswered`
    ///   - stats: `QuizViewModel.quizStats` (streak, accuracy counters updated throughout the quiz)
    static func from(
        score: Double,
        questionsAnswered: Int,
        maxQuestions: Int?,
        stats: QuizStats
    ) -> QuizCompleteSummary {
        let correct = Int(score)
        let total = maxQuestions ?? questionsAnswered
        let incorrect = max(questionsAnswered - correct, 0)
        let accuracy = questionsAnswered > 0
            ? Double(correct) / Double(questionsAnswered) * 100.0
            : 0.0
        let avg = questionsAnswered > 0 ? score / Double(questionsAnswered) : 0.0

        return QuizCompleteSummary(
            finalScore: score,
            correctCount: correct,
            incorrectCount: incorrect,
            totalAnswered: questionsAnswered,
            totalQuestions: total,
            sessionAccuracyPercent: accuracy,
            bestStreak: stats.bestStreak,
            avgPointsPerQuestion: avg
        )
    }
}
