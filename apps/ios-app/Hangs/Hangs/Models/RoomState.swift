//
//  RoomState.swift
//  Hangs
//
//  #212: a same-room game as one phone sees it (`GET /rooms/{id}/state`).
//

import Foundation

/// The server leaves every null field out, so everything past the version is
/// optional; an unchanged poll is just `room_id`, `version`, `changed: false`.
nonisolated struct RoomState: Decodable, Sendable, Equatable {
    let roomId: String
    let version: Int
    let changed: Bool
    let status: Status?
    let you: String?
    let isHost: Bool?
    let questionNumber: Int?
    let maxQuestions: Int?
    let players: [Player]?
    let revealMode: RevealMode?
    /// #213.8: the room's rules, in the lobby too; nil from an older server.
    let thinkingSeconds: Int?
    let readsAloud: Bool?
    let question: Question?
    let round: Round?
    let finishedReason: String?
    let ranking: [Rank]?
    let rounds: [Round]?
    let away: [Away]?

    enum Status: String, Decodable, Sendable {
        case lobby, playing, finished
    }

    enum RevealMode: String, Codable, CaseIterable, Sendable {
        case question, round
    }

    struct Player: Decodable, Sendable, Equatable, Identifiable {
        let participantId: String
        let displayName: String
        let color: String?
        let isHost: Bool
        let score: Double

        var id: String { participantId }

        enum CodingKeys: String, CodingKey {
            case participantId = "participant_id"
            case displayName = "display_name"
            case color
            case isHost = "is_host"
            case score
        }
    }

    struct Round: Decodable, Sendable, Equatable {
        enum Phase: String, Decodable, Sendable {
            case reading, answering, grading, revealed
        }

        let questionId: String
        let number: Int
        let questionText: String
        let phase: Phase
        let remainingMs: Int?
        let answered: [String]
        let yourAnswer: String?
        let correctAnswer: String?
        let explanation: String?
        let results: [Result]?

        enum CodingKeys: String, CodingKey {
            case questionId = "question_id"
            case number
            case questionText = "question_text"
            case phase
            case remainingMs = "remaining_ms"
            case answered
            case yourAnswer = "your_answer"
            case correctAnswer = "correct_answer"
            case explanation
            case results
        }
    }

    struct Result: Decodable, Sendable, Equatable {
        let participantId: String
        let answer: String
        let result: String
        let points: Double

        var isCorrect: Bool { result == "correct" }

        enum CodingKeys: String, CodingKey {
            case participantId = "participant_id"
            case answer, result, points
        }
    }

    struct Rank: Decodable, Sendable, Equatable {
        let participantId: String
        let rank: Int
        let score: Double
        let correctCount: Int

        enum CodingKeys: String, CodingKey {
            case participantId = "participant_id"
            case rank, score
            case correctCount = "correct_count"
        }
    }

    struct Away: Decodable, Sendable, Equatable {
        let participantId: String
        let questions: Int

        enum CodingKeys: String, CodingKey {
            case participantId = "participant_id"
            case questions
        }
    }

    enum CodingKeys: String, CodingKey {
        case roomId = "room_id"
        case version, changed, status, you
        case isHost = "is_host"
        case questionNumber = "question_number"
        case maxQuestions = "max_questions"
        case players
        case revealMode = "reveal_mode"
        case thinkingSeconds = "thinking_seconds"
        case readsAloud = "reads_aloud"
        case question, round
        case finishedReason = "finished_reason"
        case ranking, rounds, away
    }
}
