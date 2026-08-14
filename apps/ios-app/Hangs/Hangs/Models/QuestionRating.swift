//
//  QuestionRating.swift
//  Hangs
//
//  Wire models for the canonical rating store (#154), used by the in-app
//  rating panel (#155). Contract = quiz-pack-api `POST /v1/ratings`
//  (`InAppRatingRequest` / `RatingSavedResponse`). Field names are snake_case
//  exactly — explicit CodingKeys, no automatic conversion, mirroring
//  `PackOrder.swift`.
//
//  The rater is NOT sent: the server derives it from the bearer JWT subject,
//  which is what makes a re-rating replace the previous score instead of
//  forking a second row.
//

@preconcurrency import Foundation

/// Body of `POST /v1/ratings`. `reason`/`display_name` are omitted when nil.
nonisolated struct QuestionRatingRequest: Encodable, Sendable {
    let questionId: String
    /// 1…10, higher = better (the #154 scale; the backend rejects anything else).
    let score: Int
    let reason: String?
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case questionId = "question_id"
        case score
        case reason
        case displayName = "display_name"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(questionId, forKey: .questionId)
        try container.encode(score, forKey: .score)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encodeIfPresent(displayName, forKey: .displayName)
    }
}

/// `RatingSavedResponse` — the stored row's identity. `score` arrives as a JSON
/// number (the store keeps it as a float), so it decodes as `Double`.
nonisolated struct QuestionRatingResponse: Decodable, Sendable, Equatable {
    let ratingId: String
    let rater: String
    let score: Double
    let ratedAt: String

    enum CodingKeys: String, CodingKey {
        case ratingId = "rating_id"
        case rater
        case score
        case ratedAt = "rated_at"
    }
}
