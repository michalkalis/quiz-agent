//
//  NetworkDecodingTests.swift
//  HangsTests
//
//  Tests for Codable model decoding edge cases and safe collection access.
//

import Foundation
@testable import Hangs
import Testing

// MARK: - Network Response Decoding Tests

@Suite("Network Response Decoding Tests")
struct NetworkDecodingTests {
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    // MARK: - Question Decoding

    @Test("JSON with possible_answers: null decodes to nil")
    func decodeQuestionWithNullPossibleAnswers() throws {
        let json = """
        {
            "id": "q_001",
            "question": "What is 2+2?",
            "type": "text",
            "possible_answers": null,
            "difficulty": "easy",
            "topic": "Math",
            "category": "adults",
            "source_url": null,
            "source_excerpt": null,
            "media_url": null,
            "image_subtype": null,
            "explanation": null
        }
        """
        let data = json.data(using: .utf8)!
        let question = try JSONDecoder().decode(Question.self, from: data)

        #expect(question.id == "q_001")
        #expect(question.possibleAnswers == nil)
    }

    @Test("JSON with possible_answers: {} decodes to empty dict")
    func decodeQuestionWithEmptyPossibleAnswers() throws {
        let json = """
        {
            "id": "q_002",
            "question": "What color is the sky?",
            "type": "text",
            "possible_answers": {},
            "difficulty": "easy",
            "topic": "Science",
            "category": "adults",
            "source_url": null,
            "source_excerpt": null,
            "media_url": null,
            "image_subtype": null,
            "explanation": null
        }
        """
        let data = json.data(using: .utf8)!
        let question = try JSONDecoder().decode(Question.self, from: data)

        #expect(question.possibleAnswers != nil)
        #expect(question.possibleAnswers?.isEmpty == true)
    }

    @Test("JSON with unknown question type falls back to .text")
    func decodeQuestionWithUnknownType() throws {
        let json = """
        {
            "id": "q_003",
            "question": "Unknown type question",
            "type": "future_type",
            "possible_answers": null,
            "difficulty": "medium",
            "topic": "General",
            "category": "adults",
            "source_url": null,
            "source_excerpt": null,
            "media_url": null,
            "image_subtype": null,
            "explanation": null
        }
        """
        let data = json.data(using: .utf8)!
        let question = try JSONDecoder().decode(Question.self, from: data)

        #expect(question.type == .text)
    }

    @Test("JSON with headline_answer decodes into headlineAnswer (open-branch field)")
    func decodeQuestionWithHeadlineAnswer() throws {
        let json = """
        {
            "id": "q_open_1",
            "question": "Why are Ferraris red?",
            "type": "text",
            "possible_answers": null,
            "difficulty": "medium",
            "topic": "Cars",
            "category": "adults",
            "source_url": null,
            "source_excerpt": null,
            "media_url": null,
            "image_subtype": null,
            "explanation": "Red was Italy's international auto racing colour.",
            "headline_answer": "Italian racing colour"
        }
        """
        let data = json.data(using: .utf8)!
        let question = try JSONDecoder().decode(Question.self, from: data)

        #expect(question.headlineAnswer == "Italian racing colour")
    }

    @Test("Question without headline_answer decodes headlineAnswer as nil (closed branch)")
    func decodeQuestionWithoutHeadlineAnswer() throws {
        let json = """
        {
            "id": "q_closed_1",
            "question": "What is 2+2?",
            "type": "text",
            "possible_answers": null,
            "difficulty": "easy",
            "topic": "Math",
            "category": "adults",
            "source_url": null,
            "source_excerpt": null,
            "media_url": null,
            "image_subtype": null,
            "explanation": null
        }
        """
        let data = json.data(using: .utf8)!
        let question = try JSONDecoder().decode(Question.self, from: data)

        #expect(question.headlineAnswer == nil)
    }

    // MARK: - isMultipleChoice Logic

    @Test("Question with nil possibleAnswers is not multiple choice")
    func isMultipleChoiceWithNilAnswers() {
        let question = Question(
            id: "q_nil", question: "Test?", type: .textMultichoice,
            possibleAnswers: nil, difficulty: "easy",
            topic: "Test", category: "test",
            sourceUrl: nil, sourceExcerpt: nil,
            mediaUrl: nil, imageSubtype: nil,
            explanation: nil, generatedBy: nil
        )

        #expect(question.isMultipleChoice == false)
    }

    @Test("Question with empty dict possibleAnswers is not multiple choice")
    func isMultipleChoiceWithEmptyAnswers() {
        let question = Question(
            id: "q_empty", question: "Test?", type: .textMultichoice,
            possibleAnswers: [:], difficulty: "easy",
            topic: "Test", category: "test",
            sourceUrl: nil, sourceExcerpt: nil,
            mediaUrl: nil, imageSubtype: nil,
            explanation: nil, generatedBy: nil
        )

        #expect(question.isMultipleChoice == false)
    }

    @Test("Question with valid MCQ answers is multiple choice")
    func isMultipleChoiceWithValidAnswers() {
        let question = Question(
            id: "q_mcq", question: "Pick one?", type: .textMultichoice,
            possibleAnswers: ["a": "Mars", "b": "Jupiter", "c": "Saturn", "d": "Neptune"],
            difficulty: "easy",
            topic: "Science", category: "adults",
            sourceUrl: nil, sourceExcerpt: nil,
            mediaUrl: nil, imageSubtype: nil,
            explanation: nil, generatedBy: nil
        )

        #expect(question.isMultipleChoice == true)
        #expect(question.sortedAnswerOptions.count == 4)
        #expect(question.sortedAnswerOptions.first?.key == "a")
    }

    // MARK: - Evaluation Decoding

    @Test("Evaluation decodes all result variants")
    func decodeEvaluationWithAllResults() throws {
        let cases: [(String, Evaluation.EvaluationResult)] = [
            ("correct", .correct),
            ("incorrect", .incorrect),
            ("partially_correct", .partiallyCorrect),
            ("partially_incorrect", .partiallyIncorrect),
            ("skipped", .skipped),
        ]

        for (rawValue, expected) in cases {
            let json = """
            {
                "user_answer": "Test",
                "result": "\(rawValue)",
                "points": 0.5,
                "correct_answer": "Expected",
                "question_id": "q_001",
                "explanation": null
            }
            """
            let data = json.data(using: .utf8)!
            let evaluation = try JSONDecoder().decode(Evaluation.self, from: data)

            #expect(evaluation.result == expected, "Expected \(expected) for raw value '\(rawValue)'")
        }
    }

    @Test("Evaluation decodes headline_answer and tolerates its absence")
    func decodeEvaluationHeadlineAnswer() throws {
        let withHeadline = """
        {
            "user_answer": "Italian racing colour",
            "result": "correct",
            "points": 1.0,
            "correct_answer": "Red was Italy's international auto racing colour.",
            "question_id": "q_open_1",
            "explanation": "Red was Italy's international auto racing colour.",
            "headline_answer": "Italian racing colour"
        }
        """
        let evalWith = try JSONDecoder().decode(Evaluation.self, from: withHeadline.data(using: .utf8)!)
        #expect(evalWith.headlineAnswer == "Italian racing colour")

        let withoutHeadline = """
        {
            "user_answer": "Paris",
            "result": "correct",
            "points": 1.0,
            "correct_answer": "Paris",
            "question_id": "q_closed_1",
            "explanation": null
        }
        """
        let evalWithout = try JSONDecoder().decode(Evaluation.self, from: withoutHeadline.data(using: .utf8)!)
        #expect(evalWithout.headlineAnswer == nil)
    }

    // MARK: - Safe Collection Subscript

    @Test("Safe subscript returns value for valid index, nil for out-of-bounds")
    func safeCollectionSubscript() {
        let array = ["a", "b", "c"]

        // Valid index returns value
        #expect(array[safe: 0] == "a")
        #expect(array[safe: 1] == "b")
        #expect(array[safe: 2] == "c")

        // Out-of-bounds returns nil
        #expect(array[safe: 3] == nil)
        #expect(array[safe: -1] == nil)
        #expect(array[safe: 100] == nil)

        // Empty collection returns nil
        let empty: [String] = []
        #expect(empty[safe: 0] == nil)
    }
}
