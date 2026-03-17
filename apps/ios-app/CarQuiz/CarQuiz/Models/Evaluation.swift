//
//  Evaluation.swift
//  CarQuiz
//
//  Answer evaluation result model matching backend API
//

import Foundation

/// Represents the evaluation result of a user's answer
struct Evaluation: Codable, Equatable, Sendable {
    let userAnswer: String
    let result: EvaluationResult
    let points: Double
    let correctAnswer: String
    let questionId: String?
    let explanation: String?

    enum CodingKeys: String, CodingKey {
        case userAnswer = "user_answer"
        case result
        case points
        case correctAnswer = "correct_answer"
        case questionId = "question_id"
        case explanation
    }
}

/// Evaluation result types
extension Evaluation {
    enum EvaluationResult: String, Codable, Sendable {
        case correct
        case incorrect
        case partiallyCorrect = "partially_correct"
        case partiallyIncorrect = "partially_incorrect"
        case skipped
    }

    var isCorrect: Bool {
        result == .correct
    }

    var isPartial: Bool {
        result == .partiallyCorrect || result == .partiallyIncorrect
    }

    var isWrong: Bool {
        result == .incorrect
    }

    var wasSkipped: Bool {
        result == .skipped
    }

    /// Get user-friendly result message
    var resultMessage: String {
        switch result {
        case .correct:
            return "Correct!"
        case .incorrect:
            return "Incorrect"
        case .partiallyCorrect:
            return "Partially Correct"
        case .partiallyIncorrect:
            return "Partially Incorrect"
        case .skipped:
            return "Skipped"
        }
    }

    /// Get color for result display
    var resultColor: String {
        switch result {
        case .correct:
            return "green"
        case .incorrect:
            return "red"
        case .partiallyCorrect, .partiallyIncorrect:
            return "orange"
        case .skipped:
            return "gray"
        }
    }
}

// MARK: - Preview Helpers

#if DEBUG
extension Evaluation {
    static let previewCorrect = Evaluation(
        userAnswer: "Paris",
        result: .correct,
        points: 1.0,
        correctAnswer: "Paris",
        questionId: "q_preview_1",
        explanation: "Paris has been the capital of France since the 10th century."
    )

    static let previewIncorrect = Evaluation(
        userAnswer: "London",
        result: .incorrect,
        points: 0.0,
        correctAnswer: "Paris",
        questionId: "q_preview_1",
        explanation: "Paris has been the capital of France since the 10th century."
    )

    static let previewPartial = Evaluation(
        userAnswer: "Paris, France",
        result: .partiallyCorrect,
        points: 0.5,
        correctAnswer: "Paris",
        questionId: "q_preview_1",
        explanation: nil
    )
}
#endif
