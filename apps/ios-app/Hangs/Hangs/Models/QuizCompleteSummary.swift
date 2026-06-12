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

    /// Final score for display — whole numbers drop the trailing ".0"; fractional
    /// scores from partial credit show one decimal (54.13: never `Int()`-floored).
    var displayScore: String {
        if finalScore == finalScore.rounded() {
            return "\(Int(finalScore))"
        }
        return String(format: "%.1f", finalScore)
    }

    /// Aggregate from the primitive values available on QuizViewModel at .finished state.
    /// - Parameters:
    ///   - score: `QuizViewModel.score` (backend points; partial credit makes it fractional)
    ///   - questionsAnswered: `QuizViewModel.questionsAnswered`
    ///   - correctCount: per-session count of `.correct` evaluations (54.13: counts come
    ///     from actual results, never derived from the fractional score)
    ///   - incorrectCount: per-session count of `.incorrect` evaluations — partials and
    ///     skips land in neither bucket, so correct + incorrect ≤ answered always holds
    ///   - maxQuestions: `QuizViewModel.currentSession?.maxQuestions` — falls back to `questionsAnswered`
    ///   - stats: `QuizViewModel.quizStats` (streak, accuracy counters updated throughout the quiz)
    static func from(
        score: Double,
        questionsAnswered: Int,
        correctCount: Int,
        incorrectCount: Int,
        maxQuestions: Int?,
        stats: QuizStats
    ) -> QuizCompleteSummary {
        let total = maxQuestions ?? questionsAnswered
        let accuracy = questionsAnswered > 0
            ? Double(correctCount) / Double(questionsAnswered) * 100.0
            : 0.0
        let avg = questionsAnswered > 0 ? score / Double(questionsAnswered) : 0.0

        return QuizCompleteSummary(
            finalScore: score,
            correctCount: correctCount,
            incorrectCount: incorrectCount,
            totalAnswered: questionsAnswered,
            totalQuestions: total,
            sessionAccuracyPercent: accuracy,
            bestStreak: stats.bestStreak,
            avgPointsPerQuestion: avg
        )
    }
}
