//
//  UsageInfo.swift
//  CarQuiz
//
//  Usage stats from backend for freemium limit tracking
//

import Foundation

/// Usage information returned by GET /api/v1/usage/{user_id}
nonisolated struct UsageInfo: Codable, Sendable, Equatable {
    let userId: String
    let isPremium: Bool
    let questionsUsed: Int
    let questionsLimit: Int?
    let remaining: Int?
    let resetsAt: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case isPremium = "is_premium"
        case questionsUsed = "questions_used"
        case questionsLimit = "questions_limit"
        case remaining
        case resetsAt = "resets_at"
    }

    /// Parsed reset time
    var resetDate: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: resetsAt) ?? ISO8601DateFormatter().date(from: resetsAt)
    }

    /// Whether the free limit has been reached
    var isLimitReached: Bool {
        guard !isPremium else { return false }
        guard let remaining else { return false }
        return remaining <= 0
    }
}

/// Error detail returned by 429 response
nonisolated struct DailyLimitError: Codable, Sendable {
    let error: String
    let questionsUsed: Int
    let questionsLimit: Int
    let resetsAt: String
    let upgradeAvailable: Bool

    enum CodingKeys: String, CodingKey {
        case error
        case questionsUsed = "questions_used"
        case questionsLimit = "questions_limit"
        case resetsAt = "resets_at"
        case upgradeAvailable = "upgrade_available"
    }
}
