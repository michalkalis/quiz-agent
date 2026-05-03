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
    let ageAppropriate: String?

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
        case ageAppropriate = "age_appropriate"
    }

    /// Backward-compatible decoder — `ageAppropriate` is optional so existing
    /// questions without the field still decode without errors.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        question = try container.decode(String.self, forKey: .question)
        type = try container.decodeIfPresent(QuestionType.self, forKey: .type) ?? .text
        possibleAnswers = try container.decodeIfPresent([String: String].self, forKey: .possibleAnswers)
        difficulty = try container.decode(String.self, forKey: .difficulty)
        topic = try container.decode(String.self, forKey: .topic)
        category = try container.decode(String.self, forKey: .category)
        sourceUrl = try container.decodeIfPresent(String.self, forKey: .sourceUrl)
        sourceExcerpt = try container.decodeIfPresent(String.self, forKey: .sourceExcerpt)
        mediaUrl = try container.decodeIfPresent(String.self, forKey: .mediaUrl)
        imageSubtype = try container.decodeIfPresent(String.self, forKey: .imageSubtype)
        explanation = try container.decodeIfPresent(String.self, forKey: .explanation)
        generatedBy = try container.decodeIfPresent(String.self, forKey: .generatedBy)
        ageAppropriate = try container.decodeIfPresent(String.self, forKey: .ageAppropriate)
    }

    init(
        id: String,
        question: String,
        type: QuestionType,
        possibleAnswers: [String: String]?,
        difficulty: String,
        topic: String,
        category: String,
        sourceUrl: String?,
        sourceExcerpt: String?,
        mediaUrl: String?,
        imageSubtype: String?,
        explanation: String?,
        generatedBy: String?,
        ageAppropriate: String? = nil
    ) {
        self.id = id
        self.question = question
        self.type = type
        self.possibleAnswers = possibleAnswers
        self.difficulty = difficulty
        self.topic = topic
        self.category = category
        self.sourceUrl = sourceUrl
        self.sourceExcerpt = sourceExcerpt
        self.mediaUrl = mediaUrl
        self.imageSubtype = imageSubtype
        self.explanation = explanation
        self.generatedBy = generatedBy
        self.ageAppropriate = ageAppropriate
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
