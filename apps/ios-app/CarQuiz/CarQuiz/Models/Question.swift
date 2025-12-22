//
//  Question.swift
//  CarQuiz
//
//  Quiz question model matching backend API
//

import Foundation

/// Represents a quiz question
struct Question: Codable, Identifiable, Sendable {
    let id: String
    let question: String
    let type: QuestionType
    let possibleAnswers: [String]?
    let difficulty: String
    let topic: String
    let category: String

    enum CodingKeys: String, CodingKey {
        case id
        case question
        case type
        case possibleAnswers = "possible_answers"
        case difficulty
        case topic
        case category
    }
}

/// Question types
extension Question {
    enum QuestionType: String, Codable, Sendable {
        case text
        case textMultichoice = "text_multichoice"
    }

    enum Difficulty: String, Codable, Sendable {
        case easy
        case medium
        case hard
        case random
    }

    var difficultyEnum: Difficulty? {
        Difficulty(rawValue: difficulty)
    }
}

// MARK: - Preview Helpers

#if DEBUG
extension Question {
    static let preview = Question(
        id: "q_preview_123",
        question: "What is the capital of France?",
        type: .text,
        possibleAnswers: nil,
        difficulty: "easy",
        topic: "Geography",
        category: "adults"
    )

    static let previewHard = Question(
        id: "q_preview_456",
        question: "What is the chemical formula for sulfuric acid?",
        type: .text,
        possibleAnswers: nil,
        difficulty: "hard",
        topic: "Chemistry",
        category: "adults"
    )
}
#endif
