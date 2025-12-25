//
//  Session.swift
//  CarQuiz
//
//  Quiz session model matching backend API
//

@preconcurrency import Foundation

/// Represents a quiz session
struct QuizSession: Codable, Identifiable, Sendable {
    let id: String  // session_id from backend
    let mode: String
    let phase: String
    let maxQuestions: Int
    let currentDifficulty: String
    let category: String?
    let language: String
    let participants: [Participant]
    let expiresAt: Date
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id = "session_id"
        case mode
        case phase
        case maxQuestions = "max_questions"
        case currentDifficulty = "current_difficulty"
        case category
        case language
        case participants
        case expiresAt = "expires_at"
        case createdAt = "created_at"
    }
}

/// Session phase states
extension QuizSession {
    enum Phase: String {
        case idle
        case asking
        case awaitingAnswer = "awaiting_answer"
        case finished
    }

    var phaseEnum: Phase? {
        Phase(rawValue: phase)
    }

    var isActive: Bool {
        phase == "asking" || phase == "awaiting_answer"
    }

    var isFinished: Bool {
        phase == "finished"
    }

    var isExpired: Bool {
        expiresAt < Date()
    }
}

/// Participant in a quiz session
struct Participant: Codable, Identifiable, Sendable {
    let id: String  // participant_id from backend
    let userId: String?
    let displayName: String
    let score: Double
    let answeredCount: Int
    let correctCount: Int
    let lastAnswer: String?
    let lastResult: String?
    let isHost: Bool
    let isReady: Bool
    let joinedAt: Date

    enum CodingKeys: String, CodingKey {
        case id = "participant_id"
        case userId = "user_id"
        case displayName = "display_name"
        case score
        case answeredCount = "answered_count"
        case correctCount = "correct_count"
        case lastAnswer = "last_answer"
        case lastResult = "last_result"
        case isHost = "is_host"
        case isReady = "is_ready"
        case joinedAt = "joined_at"
    }
}
