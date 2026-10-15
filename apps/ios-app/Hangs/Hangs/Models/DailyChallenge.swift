//
//  DailyChallenge.swift
//  Hangs
//
//  #205 — daily challenge: player vs the crowd. Wire models mirroring
//  `apps/quiz-agent/app/daily_challenge/schemas.py` and the start response in
//  `apps/quiz-agent/app/api/routes/daily_challenge.py`. Every crowd text
//  (strip, comparison, rank, best hit) arrives ready in the session language
//  and is shown verbatim, never rebuilt here.
//

import Foundation

/// `GET /api/v1/daily-challenge`: played or not, and the live crowd numbers.
nonisolated struct DailyChallengeState: Codable, Sendable, Equatable {
    enum Status: String, Codable, Sendable {
        case notPlayed = "not_played"
        case inProgress = "in_progress"
        case played
    }

    /// The player's local date, `YYYY-MM-DD`.
    let date: String
    let language: String
    let status: Status
    /// Questions in the challenge.
    let total: Int
    let summary: DailySummary?
}

/// A finished challenge, computed live by the server on every request.
nonisolated struct DailySummary: Codable, Sendable, Equatable {
    let score: Int
    let total: Int
    /// Per question in play order: knew it, missed it, or nil (never answered).
    let marks: [Bool?]
    /// Players who finished today, the player included.
    let players: Int
    /// "Dnes si prvý.", the rank (top half only) or "Ťažká výzva.".
    let comparison: String?
    /// The rank line, only in the top half (used by the share text).
    let rank: String?
    let bestHit: DailyBestHit?

    enum CodingKeys: String, CodingKey {
        case score, total, marks, players, comparison, rank
        case bestHit = "best_hit"
    }
}

/// The rarest question the player knew, shown last on the round end.
nonisolated struct DailyBestHit: Codable, Sendable, Equatable {
    let questionId: String
    let question: String
    let answer: String
    /// At most 30 % of the others knew it.
    let rare: Bool
    /// The crowd line for it, e.g. "Vedeli to len 2 z 9.".
    let text: String

    enum CodingKeys: String, CodingKey {
        case questionId = "question_id"
        case question, answer, rare, text
    }
}

/// The strip under the correct answer on a daily-challenge result card.
nonisolated struct CrowdStrip: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        /// Nobody else answered yet: text only, no meter.
        case first
        /// At most 30 % of the others knew it and the player did.
        case rare
        /// A common correct answer.
        case plain
        /// At most 30 % of the others knew it and the player missed it.
        case hard
    }

    let kind: Kind
    let text: String
    /// Other players who answered this question today.
    let others: Int
    /// How many of them knew it.
    let knew: Int

    /// The meter's fill, 0…1; nil when there is nothing to compare with.
    var knewFraction: Double? {
        guard kind != .first, others > 0 else { return nil }
        return min(1, max(0, Double(knew) / Double(others)))
    }
}

/// `POST /api/v1/daily-challenge/start`: a session to play, or (already played)
/// only the finished state. Decoded on the main actor, like `QuizSession`.
struct DailyStartResult: Decodable, Sendable {
    let state: DailyChallengeState
    let session: QuizSession?
}
