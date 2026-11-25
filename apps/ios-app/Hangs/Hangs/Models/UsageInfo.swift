//
//  UsageInfo.swift
//  Hangs
//
//  Usage stats from backend for freemium limit tracking
//

import Foundation

/// Usage information returned by GET /api/v1/usage/me
nonisolated struct UsageInfo: Codable, Sendable, Equatable {
    let userId: String
    let isPremium: Bool
    let questionsUsed: Int
    let questionsLimit: Int?
    let remaining: Int?
    let resetsAt: String
    /// Stored subscription status (`active`|`grace`|`expired`) or `"none"` (issue #93).
    let subscriptionStatus: String
    /// Pack-credit balance = SUM(credit_ledger.delta) (issue #93).
    let creditBalance: Int
    /// Free tier split (founder 2026-11-21): of the free questions, only
    /// `voiceAnswersLimit` a month may be answered by voice. A nil limit means
    /// voice is not limited (Trubbo Plus, pack credits, or a server older than
    /// the split, which sends none of the three).
    var voiceAnswersUsed: Int? = nil
    var voiceAnswersLimit: Int? = nil
    var voiceAnswersRemaining: Int? = nil

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case isPremium = "is_premium"
        case questionsUsed = "questions_used"
        case questionsLimit = "questions_limit"
        case remaining
        case resetsAt = "resets_at"
        case subscriptionStatus = "subscription_status"
        case creditBalance = "credit_balance"
        case voiceAnswersUsed = "voice_answers_used"
        case voiceAnswersLimit = "voice_answers_limit"
        case voiceAnswersRemaining = "voice_answers_remaining"
    }

    /// Parsed reset time
    var resetDate: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: resetsAt) ?? ISO8601DateFormatter().date(from: resetsAt)
    }

    /// Whether the account holds Trubbo Plus. The server grants it from the
    /// stored subscription status (`active` or `grace`); the legacy
    /// `is_premium` flag has no production writer, so it can never be the
    /// only signal (#199 review). Every "is this a subscriber?" check reads
    /// this one property so Home, Settings, the paywall touchpoints and the
    /// purchase verdict cannot disagree on the same payload.
    var isPlus: Bool {
        isPremium || subscriptionStatus == "active" || subscriptionStatus == "grace"
    }

    /// Whether the monthly allowance (free tier or Trubbo Plus) has been
    /// reached. Nil `remaining` (no limit known) never counts as reached.
    var isLimitReached: Bool {
        guard let remaining else { return false }
        return remaining <= 0
    }

    /// This month's voice answers are used up: the player answers by typing
    /// or tapping until the reset. Never true when voice is not limited.
    var isVoiceAllowanceSpent: Bool {
        guard voiceAnswersLimit != nil, let voiceAnswersRemaining else { return false }
        return voiceAnswersRemaining <= 0
    }
}

/// The 429 a voice answer gets once the free voice allowance is used up
/// (`{"detail": {"code": "voice_limit_reached", ...}}`, sent only to a session
/// that declared the `voice-allowance` capability). Nothing was transcribed
/// or charged; the question is still open for a typed or tapped answer.
nonisolated struct VoiceLimitError: Codable, Sendable, Equatable {
    let code: String
    let voiceAnswersUsed: Int
    let voiceAnswersLimit: Int
    let resetsAt: String

    static let reachedCode = "voice_limit_reached"

    enum CodingKeys: String, CodingKey {
        case code
        case voiceAnswersUsed = "voice_answers_used"
        case voiceAnswersLimit = "voice_answers_limit"
        case resetsAt = "resets_at"
    }
}

/// Error detail returned by 429 response
nonisolated struct QuotaLimitError: Codable, Sendable {
    let error: String
    let questionsUsed: Int
    let questionsLimit: Int
    let resetsAt: String
    let upgradeAvailable: Bool
    /// #240.9: a mid-round 429 still carries the verdict of the answer that
    /// reached the limit (the server graded it first). Absent on the start gate.
    var evaluation: Evaluation? = nil

    enum CodingKeys: String, CodingKey {
        case error
        case questionsUsed = "questions_used"
        case questionsLimit = "questions_limit"
        case resetsAt = "resets_at"
        case upgradeAvailable = "upgrade_available"
        case evaluation
    }

    /// Parsed reset time — the same parsing as `UsageInfo.resetDate`.
    var resetDate: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: resetsAt) ?? ISO8601DateFormatter().date(from: resetsAt)
    }
}
