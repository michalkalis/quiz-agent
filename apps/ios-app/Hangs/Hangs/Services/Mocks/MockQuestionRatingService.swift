//
//  MockQuestionRatingService.swift
//  Hangs
//
//  Canned QuestionRatingServiceProtocol for previews + unit tests (#155).
//  NOT #if DEBUG-gated: it is the default injected into AppState's test/preview
//  init, which is compiled in every configuration.
//
//  Captures the exact payload each call carried — the panel's whole job is to
//  put {question id, score, justification} in the #154 store, so a test that
//  can't see the payload can't prove the feature works.
//

import Foundation
import os

/// One captured `submitRating` call.
struct CapturedRating: Equatable, Sendable {
    let questionId: String
    let score: Int
    let reason: String?
    let displayName: String?
}

final class MockQuestionRatingService: QuestionRatingServiceProtocol, Sendable {
    /// Boxed error so the config stays value-typed / Sendable.
    struct RatingFailure: Error, Sendable {
        let message: String
        init(_ message: String = "mock rating failure") { self.message = message }
    }

    private let result: Result<QuestionRatingResponse, RatingFailure>
    /// Artificial latency, in seconds — lets a test observe the in-flight state.
    private let delaySeconds: Double
    private let calls = OSAllocatedUnfairLock<[CapturedRating]>(initialState: [])

    init(
        result: Result<QuestionRatingResponse, RatingFailure> = .success(.mockSaved),
        delaySeconds: Double = 0
    ) {
        self.result = result
        self.delaySeconds = delaySeconds
    }

    var capturedRatings: [CapturedRating] { calls.withLock { $0 } }

    func submitRating(
        questionId: String,
        score: Int,
        reason: String?,
        displayName: String?
    ) async throws -> QuestionRatingResponse {
        calls.withLock {
            $0.append(CapturedRating(questionId: questionId, score: score, reason: reason, displayName: displayName))
        }
        if delaySeconds > 0 {
            try await Task.sleep(for: .seconds(delaySeconds))
        }
        return try result.get()
    }
}

extension QuestionRatingResponse {
    static let mockSaved = QuestionRatingResponse(
        ratingId: "99999999-9999-9999-9999-999999999999",
        rater: "user-subject",
        score: 8,
        ratedAt: "2026-08-14T10:00:00Z"
    )
}
