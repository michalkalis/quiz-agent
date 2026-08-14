//
//  QuestionRatingService.swift
//  Hangs
//
//  REST client for quiz-pack-api `POST /v1/ratings` (#154 store, #155 in-app
//  panel). Actor-based like `PackOrderService`, and for the same reason it is a
//  separate client from `NetworkService`: this endpoint lives on the pack-api
//  host (`Config.packApiBaseURL`), not the quiz-agent hot path.
//
//  Authorisation is the account bearer only — the backend's `require_user`
//  derives the rater from the JWT subject. No admin key, no StoreKit proof.
//

@preconcurrency import Foundation
import os

protocol QuestionRatingServiceProtocol: Sendable {
    /// `POST /v1/ratings` — store (or replace) this rater's score for one
    /// question. Re-rating the same question overwrites the previous row
    /// server-side, so callers never need to check for an existing rating.
    func submitRating(
        questionId: String,
        score: Int,
        reason: String?,
        displayName: String?
    ) async throws -> QuestionRatingResponse
}

actor QuestionRatingService: QuestionRatingServiceProtocol {
    private let baseURL: URL
    private let session: URLSession
    private let authService: AuthServiceProtocol?

    init(
        baseURL: String = Config.packApiBaseURL,
        session: URLSession = .shared,
        authService: AuthServiceProtocol?
    ) {
        guard let url = URL(string: baseURL) else {
            fatalError("QuestionRatingService: invalid baseURL '\(baseURL)' — check Config.packApiBaseURL")
        }
        self.baseURL = url
        self.session = session
        self.authService = authService
    }

    func submitRating(
        questionId: String,
        score: Int,
        reason: String?,
        displayName: String?
    ) async throws -> QuestionRatingResponse {
        let url = baseURL.appendingPathComponent("/v1/ratings")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            QuestionRatingRequest(
                questionId: questionId,
                score: score,
                reason: reason,
                displayName: displayName
            )
        )

        Logger.network.debug("🌐 POST \(url, privacy: .public) (rate question)")
        let (data, response) = try await send(request)

        guard let http = response as? HTTPURLResponse else {
            throw QuestionRatingError.invalidResponse
        }
        guard http.statusCode != 401 else {
            throw QuestionRatingError.unauthorized
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw QuestionRatingError.server(Self.errorMessage(from: data))
        }
        return try JSONDecoder().decode(QuestionRatingResponse.self, from: data)
    }

    /// Same 401-refresh-retry convention as every other authorized client
    /// (`AuthServiceProtocol.sendAuthorized`): it attaches the bearer and, on a
    /// 401, refreshes the access token once and retries. With no `authService`
    /// (unit tests) the request goes out unchanged.
    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard let authService else {
            return try await session.data(for: request)
        }
        return try await authService.sendAuthorized(request, on: session)
    }

    /// Hand-raised FastAPI errors are `{"detail": "<string>"}`; Pydantic
    /// validation errors are `{"detail": [ … ]}` — the array form fails the
    /// string decode and falls back to the generic message.
    private nonisolated static func errorMessage(from data: Data) -> String {
        if let decoded = try? JSONDecoder().decode(RatingDetailError.self, from: data) {
            return decoded.detail
        }
        return String(localized: "The rating service returned an error. Please try again.", comment: "Fallback message when the ratings API returns a non-2xx response we can't parse")
    }
}

private nonisolated struct RatingDetailError: Decodable, Sendable {
    let detail: String
}

enum QuestionRatingError: LocalizedError, Equatable {
    case invalidResponse
    /// A 401 that survived the refresh-and-retry — the session is gone, not
    /// merely expired.
    case unauthorized
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return String(localized: "Invalid response from the rating service", comment: "Rating error: malformed server response")
        case .unauthorized:
            return String(localized: "Your session expired. Please sign in again to continue.", comment: "Rating error: the request was still unauthorized after a token refresh")
        case let .server(message):
            // Server-provided message — already human-readable, do not wrap.
            return message
        }
    }
}
