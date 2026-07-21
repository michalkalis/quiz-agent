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
        /// Number of times `getUsage` was invoked — asserts the post-restore
        /// reconciliation bridge (#102 finding 3) actually refreshes usage, not
        /// just entitlements.
        var getUsageCallCount = 0

        // Capture properties for unit-test assertions (additive — no behaviour change)
        var capturedTextInputAudio: Bool?
        var capturedTextInputInput: String?
        /// Number of times `submitTextInput` was invoked — the #79 typed↔voice race
        /// tests assert exactly ONE submission survives an interleaving.
        var submitTextInputCallCount = 0
        var capturedStartQuizExcludedIds: [String]?
        /// When set, `createSession` throws this error instead of the default behaviour.
        var createSessionError: Error?
        /// Number of times `createSession` was invoked — the #110 double-tap
        /// single-flight test asserts exactly ONE session is created from a
        /// concurrent Try-Again/Play-Again double-tap.
        var createSessionCallCount = 0
        /// Called at `createSession` entry — lets the #110 Try-Again test observe
        /// `quizState` DURING session creation. The pre-fix bug left the state
        /// `.error` while the flow ran on, and the end state alone cannot
        /// distinguish that (error → askingQuestion was already legal).
        var onCreateSession: (() -> Void)?
        /// When set, `endSession` throws this error instead of the default behaviour.
        /// Lets one test exercise the 404-only end-quiz path (#59.4) without making
        /// every other network call fail via `shouldFail`.
        var endSessionError: Error?
        /// When set, `submitVoiceAnswer` throws this error instead of the default behaviour.
        var submitVoiceAnswerError: Error?
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
        /// When > 0, `syncEntitlements` throws (`syncEntitlementsError` or a
        /// generic error) this many times before succeeding, decrementing on each
        /// call — lets tests assert the #102 bounded-retry-with-backoff behavior
        /// (fails N times, then recovers).
        var syncEntitlementsFailuresBeforeSuccess = 0
        /// Optional hook awaited right after incrementing the call count, before
        /// `syncEntitlements` returns/throws — lets a test deterministically hold
        /// a call in flight (no wall-clock race) to assert the #102 single-flight
        /// dedup (launch + an immediate scene `.active` must not fire two
        /// concurrent syncs).
        var syncEntitlementsGate: (@Sendable () async -> Void)?

        func createSession(maxQuestions _: Int, difficulty _: String, language _: String, categories: [String], userId _: String?, includeImages: Bool, packId _: String?) async throws -> QuizSession {
            createSessionCallCount += 1
            onCreateSession?()
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

        func startQuiz(sessionId _: String, excludedQuestionIds: [String] = []) async throws -> QuizResponse {
            capturedStartQuizExcludedIds = excludedQuestionIds
            if shouldFail {
                throw NetworkError.invalidResponse
            }
            guard let response = mockResponse else {
                throw NetworkError.invalidResponse
            }
            return response
        }

        func submitVoiceAnswer(sessionId _: String, audioData _: Data, fileName _: String) async throws -> QuizResponse {
            if let error = submitVoiceAnswerError { throw error }
            if shouldFail {
                throw NetworkError.invalidResponse
            }
            guard let response = mockResponse else {
                throw NetworkError.invalidResponse
            }
            return response
        }

        // MARK: - Feedback (#109) capture + control

        /// When set, `submitFeedback` throws this instead of succeeding — lets a test
        /// exercise the send-failure path without tripping `shouldFail` for every call.
        var feedbackError: Error?
        var submitFeedbackCallCount = 0
        var capturedFeedbackMessage: String?
        var capturedFeedbackMetadataJSON: String?
        var capturedFeedbackAppVersion: String?
        var capturedFeedbackScreenshot: Data?
        var capturedFeedbackAudio: Data?
        var capturedFeedbackLogs: String?

        func submitFeedback(message: String, metadataJSON: String?, appVersion: String?, screenshotPNG: Data?, audioWAV: Data?, logsText: String?) async throws {
            submitFeedbackCallCount += 1
            capturedFeedbackMessage = message
            capturedFeedbackMetadataJSON = metadataJSON
            capturedFeedbackAppVersion = appVersion
            capturedFeedbackScreenshot = screenshotPNG
            capturedFeedbackAudio = audioWAV
            capturedFeedbackLogs = logsText
            if let feedbackError { throw feedbackError }
            if shouldFail { throw NetworkError.invalidResponse }
        }

        func submitTextInput(sessionId _: String, input: String, audio: Bool) async throws -> QuizResponse {
            submitTextInputCallCount += 1
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

        func downloadAudio(from _: String) async throws -> Data {
            if shouldFail {
                throw NetworkError.invalidResponse
            }
            return mockAudioData ?? Data()
        }

        func endSession(sessionId _: String) async throws {
            endSessionCallCount += 1
            if let error = endSessionError { throw error }
            if shouldFail {
                throw NetworkError.invalidResponse
            }
        }

        func extendSession(sessionId _: String, minutes _: Int) async throws {
            if shouldFail {
                throw NetworkError.invalidResponse
            }
        }

        func rateQuestion(sessionId _: String, rating _: Int) async throws {
            if shouldFail {
                throw NetworkError.invalidResponse
            }
        }

        func flagQuestion(sessionId _: String, reason _: String?) async throws {
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
            getUsageCallCount += 1
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
            await syncEntitlementsGate?()
            if syncEntitlementsFailuresBeforeSuccess > 0 {
                syncEntitlementsFailuresBeforeSuccess -= 1
                throw syncEntitlementsError ?? NetworkError.invalidResponse
            }
            if let syncEntitlementsError {
                throw syncEntitlementsError
            }
            if shouldFail {
                throw NetworkError.invalidResponse
            }
        }
    }
#endif
