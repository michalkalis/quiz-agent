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

    // Capture properties for unit-test assertions (additive — no behaviour change)
    var capturedTextInputAudio: Bool?
    var capturedTextInputInput: String?
    var capturedStartQuizExcludedIds: [String]?
    /// When set, `createSession` throws this error instead of the default behaviour.
    var createSessionError: Error?

    func createSession(maxQuestions: Int, difficulty: String, language: String, category: String?, userId: String?) async throws -> QuizSession {
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

    func getUsage(userId: String) async throws -> UsageInfo {
        if shouldFail {
            throw NetworkError.invalidResponse
        }
        return UsageInfo(
            userId: userId,
            isPremium: false,
            questionsUsed: 5,
            questionsLimit: 20,
            remaining: 15,
            resetsAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(86400))
        )
    }

    func setPremium(userId: String) async throws {
        if shouldFail {
            throw NetworkError.invalidResponse
        }
    }
}
#endif
