//
//  MockNetworkService.swift
//  Hangs
//
//  Mock NetworkService for DEBUG builds (SwiftUI previews, UI-test mode).
//

@preconcurrency import Foundation
import os

#if DEBUG
@MainActor
final class MockNetworkService: NetworkServiceProtocol {
    var mockSession: QuizSession?
    var mockResponse: QuizResponse?
    /// Optional override for `submitTextInput` so UI tests can return a
    /// response that includes an `Evaluation` without overwriting the
    /// start-quiz fixture used by `startQuiz`. Falls back to `mockResponse`.
    var mockTextInputResponse: QuizResponse?
    var mockAudioData: Data?
    var shouldFail = false
    /// When set, `getUsage` returns this instead of the default fixture — lets
    /// tests pin the quota state (e.g. the ≤5-remaining completion upsell, #94).
    var stubbedUsage: UsageInfo?

    // Capture properties for unit-test assertions (additive — no behaviour change)
    var capturedTextInputAudio: Bool?
    var capturedTextInputInput: String?
    var capturedStartQuizExcludedIds: [String]?
    /// When set, `createSession` throws this error instead of the default behaviour.
    var createSessionError: Error?
    /// When set, `endSession` throws this error instead of the default behaviour.
    /// Lets one test exercise the 404-only end-quiz path (#59.4) without making
    /// every other network call fail via `shouldFail`.
    var endSessionError: Error?
    /// Number of times `endSession` was invoked — for assertions that X actually
    /// attempted server-side cleanup.
    var endSessionCallCount = 0

    /// Last `includeImages` value passed to `createSession` — asserts the Home
    /// toggle actually reaches the session request (#68).
    var capturedIncludeImages: Bool?

    /// Last `categories` value passed to `createSession` — asserts the Home
    /// multi-select actually reaches the session request (#82 item 4).
    var capturedCategories: [String]?

    /// Number of times `syncEntitlements` was invoked — asserts the post-purchase
    /// bridge (issue #93) actually fires before the usage refresh.
    var syncEntitlementsCallCount = 0
    /// When set, `syncEntitlements` throws this error instead of succeeding.
    var syncEntitlementsError: Error?

    func createSession(maxQuestions: Int, difficulty: String, language: String, categories: [String], userId: String?, includeImages: Bool, packId: String?) async throws -> QuizSession {
        capturedIncludeImages = includeImages
        capturedCategories = categories
        if let error = createSessionError { throw error }
        if shouldFail {
            throw NetworkError.invalidResponse
        }
        guard let session = mockSession else {
            throw NetworkError.invalidResponse
        }
        return session
    }

    func startQuiz(sessionId: String, excludedQuestionIds: [String] = []) async throws -> QuizResponse {
        capturedStartQuizExcludedIds = excludedQuestionIds
        if shouldFail {
            throw NetworkError.invalidResponse
        }
        guard let response = mockResponse else {
            throw NetworkError.invalidResponse
        }
        return response
    }

    func submitVoiceAnswer(sessionId: String, audioData: Data, fileName: String) async throws -> QuizResponse {
        if shouldFail {
            throw NetworkError.invalidResponse
        }
        guard let response = mockResponse else {
            throw NetworkError.invalidResponse
        }
        return response
    }

    func submitTextInput(sessionId: String, input: String, audio: Bool) async throws -> QuizResponse {
        capturedTextInputAudio = audio
        capturedTextInputInput = input
        // Mirror URLSession semantics: a cancelled enclosing Task throws
        // URLError(.cancelled) — the 54.5 self-cancelling-auto-confirm vector.
        if Task.isCancelled {
            throw URLError(.cancelled)
        }
        if shouldFail {
            throw NetworkError.invalidResponse
        }
        guard let response = mockTextInputResponse ?? mockResponse else {
            throw NetworkError.invalidResponse
        }
        return response
    }

    func downloadAudio(from urlString: String) async throws -> Data {
        if shouldFail {
            throw NetworkError.invalidResponse
        }
        return mockAudioData ?? Data()
    }

    func endSession(sessionId: String) async throws {
        endSessionCallCount += 1
        if let error = endSessionError { throw error }
        if shouldFail {
            throw NetworkError.invalidResponse
        }
    }

    func extendSession(sessionId: String, minutes: Int) async throws {
        if shouldFail {
            throw NetworkError.invalidResponse
        }
    }

    func rateQuestion(sessionId: String, rating: Int) async throws {
        if shouldFail {
            throw NetworkError.invalidResponse
        }
    }

    func flagQuestion(sessionId: String, reason: String?) async throws {
        if shouldFail {
            throw NetworkError.invalidResponse
        }
    }

    func fetchElevenLabsToken() async throws -> String {
        if shouldFail {
            throw NetworkError.invalidResponse
        }
        return "mock-elevenlabs-token"
    }

    func getUsage() async throws -> UsageInfo {
        if shouldFail {
            throw NetworkError.invalidResponse
        }
        if let stubbedUsage {
            return stubbedUsage
        }
        return UsageInfo(
            userId: "mock-subject",
            isPremium: false,
            questionsUsed: 30,
            questionsLimit: 100,
            remaining: 70,
            resetsAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(12 * 86400)),
            subscriptionStatus: "none",
            creditBalance: 0
        )
    }

    func syncEntitlements() async throws {
        syncEntitlementsCallCount += 1
        if let syncEntitlementsError {
            throw syncEntitlementsError
        }
        if shouldFail {
            throw NetworkError.invalidResponse
        }
    }
}
#endif
