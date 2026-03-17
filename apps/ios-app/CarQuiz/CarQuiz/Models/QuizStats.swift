//
//  QuizStats.swift
//  CarQuiz
//
//  Persistent quiz statistics for streak and progress tracking
//

import Foundation

/// Cumulative quiz statistics persisted across sessions
struct QuizStats: Codable, Equatable, Sendable {
    var currentStreak: Int
    var bestStreak: Int
    var totalCorrect: Int
    var totalAnswered: Int
    var totalQuizzes: Int

    static let empty = QuizStats(
        currentStreak: 0,
        bestStreak: 0,
        totalCorrect: 0,
        totalAnswered: 0,
        totalQuizzes: 0
    )

    /// Record the result of an answer and update streak
    /// - Parameter isCorrect: Whether the answer was correct (1.0 points)
    mutating func recordAnswer(isCorrect: Bool) {
        // TODO: Implement streak counting logic (~10 lines)
        //
        // 1. Increment totalAnswered
        // 2. If correct:
        //    - Increment totalCorrect
        //    - Increment currentStreak
        //    - Update bestStreak if currentStreak exceeds it
        // 3. If incorrect:
        //    - Reset currentStreak to 0
        //
        // Design choice: Should partial credit (0.5 points) count as "correct"
        // for streak purposes? The caller passes Bool, so this is decided
        // upstream. Consider what makes the streak feel rewarding.
        fatalError("recordAnswer — implement me!")
    }

    /// Record a completed quiz
    mutating func recordQuizCompleted() {
        totalQuizzes += 1
    }

    /// Accuracy percentage (0-100)
    var accuracyPercentage: Double {
        guard totalAnswered > 0 else { return 0 }
        return (Double(totalCorrect) / Double(totalAnswered)) * 100
    }
}
