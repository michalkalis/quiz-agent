//
//  Question.swift
//  Hangs
//
//  Quiz question model matching backend API
//

import Foundation

/// Represents a quiz question
struct Question: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let question: String
    let type: QuestionType
    let possibleAnswers: [String: String]?
    let difficulty: String
    let topic: String
    let category: String
    let sourceUrl: String?
    let sourceExcerpt: String?
    let mediaUrl: String?
    let imageSubtype: String?
    let explanation: String?
    let generatedBy: String?

    /// Whether this question has an associated image
    var hasImage: Bool {
        type == .image && mediaUrl != nil
    }

    /// Whether this is a multiple-choice question with options
    var isMultipleChoice: Bool {
        type == .textMultichoice && possibleAnswers?.isEmpty == false
    }

    /// Sorted answer options for consistent A/B/C/D display order
    var sortedAnswerOptions: [(key: String, value: String)] {
        guard let answers = possibleAnswers else { return [] }
        return answers.sorted { $0.key < $1.key }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case question
        case type
        case possibleAnswers = "possible_answers"
        case difficulty
        case topic
        case category
        case sourceUrl = "source_url"
        case sourceExcerpt = "source_excerpt"
        case mediaUrl = "media_url"
        case imageSubtype = "image_subtype"
        case explanation
        case generatedBy = "generated_by"
    }
}

/// Question types
extension Question {
    enum QuestionType: String, Codable, Sendable {
        case text
        case textMultichoice = "text_multichoice"
        case image

        /// Safe decoder — maps unknown type values to .text so old app versions
        /// don't crash when the backend introduces new question types.
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            self = QuestionType(rawValue: rawValue) ?? .text
        }
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
        category: "adults",
        sourceUrl: "https://en.wikipedia.org/wiki/Paris",
        sourceExcerpt: "Paris is the capital and largest city of France, situated on the Seine River.",
        mediaUrl: nil,
        imageSubtype: nil,
        explanation: "Paris has been the capital of France since the 10th century.",
        generatedBy: "claude-opus-4.6"
    )

    static let previewHard = Question(
        id: "q_preview_456",
        question: "What is the chemical formula for sulfuric acid?",
        type: .text,
        possibleAnswers: nil,
        difficulty: "hard",
        topic: "Chemistry",
        category: "adults",
        sourceUrl: nil,
        sourceExcerpt: nil,
        mediaUrl: nil,
        imageSubtype: nil,
        explanation: nil,
        generatedBy: nil
    )

    static let previewImage = Question(
        id: "q_preview_img_001",
        question: "Which Mediterranean country has this distinctive shape that resembles a high-heeled boot kicking a ball?",
        type: .image,
        possibleAnswers: nil,
        difficulty: "easy",
        topic: "Geography",
        category: "adults",
        sourceUrl: nil,
        sourceExcerpt: nil,
        mediaUrl: "https://example.com/silhouettes/italy.png",
        imageSubtype: "silhouette",
        explanation: nil,
        generatedBy: nil
    )

    static let previewMCQ = Question(
        id: "q_preview_mcq_001",
        question: "What is the largest planet in our solar system?",
        type: .textMultichoice,
        possibleAnswers: ["a": "Mars", "b": "Jupiter", "c": "Saturn", "d": "Neptune"],
        difficulty: "easy",
        topic: "Science",
        category: "adults",
        sourceUrl: nil,
        sourceExcerpt: nil,
        mediaUrl: nil,
        imageSubtype: nil,
        explanation: "Jupiter is by far the largest planet, with a mass more than twice that of all other planets combined.",
        generatedBy: "gpt-4.1"
    )
}
#endif
