//
//  SharedQuiz.swift
//  Hangs
//
//  #232: a quiz shared by link. Mirrors the responses of
//  `apps/quiz-agent/app/api/routes/shared_quiz.py`. `kind` stays a raw string
//  (round | daily | pack) so a kind added later never fails a decode.
//

import Foundation

/// `POST /shared-quizzes`: the link the sender's message carries.
nonisolated struct SharedQuizCreated: Decodable, Sendable, Equatable {
    let token: String
    let kind: String
    let language: String
    /// The pack's name; nil for a round and a daily challenge.
    let title: String?
    let categories: [String]
    let questionCount: Int

    var url: URL { SharedQuizLink.url(token: token) }

    enum CodingKeys: String, CodingKey {
        case token, kind, language, title, categories
        case questionCount = "question_count"
    }
}

/// `POST /shared-quizzes/{token}/start`: a session to play through the usual
/// `/sessions/{id}/start`, or none when this person already played it.
struct SharedQuizStart: Decodable, Sendable {
    let kind: String
    let session: QuizSession?
    let alreadyPlayed: Bool

    enum CodingKeys: String, CodingKey {
        case kind, session
        case alreadyPlayed = "already_played"
    }
}

/// `GET /shared-quizzes/{token}/results`: the comparison, best first, as the
/// server filters it for the viewer.
nonisolated struct SharedQuizResults: Decodable, Sendable, Equatable {
    let kind: String
    let language: String
    let title: String?
    let categories: [String]
    let questionCount: Int
    let players: [SharedQuizPlayer]

    enum CodingKeys: String, CodingKey {
        case kind, language, title, categories, players
        case questionCount = "question_count"
    }
}

nonisolated struct SharedQuizPlayer: Decodable, Sendable, Equatable {
    /// The name from a game together, else the server's "Hráč N".
    let name: String
    let score: Double
    let total: Int
    let isSender: Bool
    let isYou: Bool
    /// #232.2b: right or not per question, in the quiz's order (nil = skipped
    /// or not reached). Optional: a server without it leaves the row unmarked.
    let marks: [Bool?]?

    init(name: String, score: Double, total: Int, isSender: Bool = false, isYou: Bool = false, marks: [Bool?]? = nil) {
        self.name = name
        self.score = score
        self.total = total
        self.isSender = isSender
        self.isYou = isYou
        self.marks = marks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        score = try container.decode(Double.self, forKey: .score)
        total = try container.decode(Int.self, forKey: .total)
        isSender = try container.decodeIfPresent(Bool.self, forKey: .isSender) ?? false
        isYou = try container.decodeIfPresent(Bool.self, forKey: .isYou) ?? false
        // Never the reason the comparison is lost.
        marks = try? container.decodeIfPresent([Bool?].self, forKey: .marks)
    }

    enum CodingKeys: String, CodingKey {
        case name, score, total, marks
        case isSender = "is_sender"
        case isYou = "is_you"
    }
}
