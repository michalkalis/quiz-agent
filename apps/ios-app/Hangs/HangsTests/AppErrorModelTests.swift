//
//  AppErrorModelTests.swift
//  HangsTests
//
//  #52 task 52.7 — Error-state mapping.
//
//  Why these tests matter:
//  - Network connectivity / timeout failures must always produce a retryOperation CTA so
//    the Error screen wires the retry closure to re-run the last operation.
//  - Terminal failures (quotaLimitReached, sessionNotFound) must produce a goHome CTA —
//    retrying is meaningless and would loop forever.
//  - Context-driven fallbacks must produce titles that match the quiz phase,
//    so the user gets actionable feedback (not a generic message) when the error type
//    does not match a specific NetworkError case.
//  (#56: copy is now English source text; was Slovak-first per D6.)
//

import Foundation
@testable import Hangs
import Testing

@Suite("AppErrorModel mapping")
struct AppErrorModelTests {
    // MARK: - URLError (connectivity)

    @Test("no internet → retryOperation")
    func noInternet() {
        let error = URLError(.notConnectedToInternet)
        let model = AppErrorModel.from(error)

        #expect(model.retryAction == .retryOperation)
        #expect(!model.title.isEmpty)
        #expect(!model.description.isEmpty)
    }

    @Test("network connection lost → retryOperation")
    func networkConnectionLost() {
        let error = URLError(.networkConnectionLost)
        let model = AppErrorModel.from(error)

        #expect(model.retryAction == .retryOperation)
    }

    @Test("timed out → retryOperation")
    func timedOut() {
        let error = URLError(.timedOut)
        let model = AppErrorModel.from(error)

        #expect(model.retryAction == .retryOperation)
    }

    // MARK: - NetworkError (terminal)

    @Test("quotaLimitReached → goHome (retry meaningless after quota)")
    func quotaLimitReached() {
        let limitError = QuotaLimitError(
            error: "limit_reached",
            questionsUsed: 10,
            questionsLimit: 10,
            resetsAt: "2026-06-12T00:00:00Z",
            upgradeAvailable: true
        )
        let error = NetworkError.quotaLimitReached(limitError)
        let model = AppErrorModel.from(error)

        #expect(model.retryAction == .goHome)
    }

    @Test("sessionNotFound → goHome (expired session cannot be retried)")
    func sessionNotFound() {
        let error = NetworkError.sessionNotFound
        let model = AppErrorModel.from(error)

        #expect(model.retryAction == .goHome)
    }

    // MARK: - NetworkError (retryable)

    @Test("server 500 → retryOperation")
    func serverError500() {
        let error = NetworkError.serverError(statusCode: 500, message: "Internal server error")
        let model = AppErrorModel.from(error)

        #expect(model.retryAction == .retryOperation)
    }

    @Test("server 503 → retryOperation")
    func serverError503() {
        let error = NetworkError.serverError(statusCode: 503, message: "Service unavailable")
        let model = AppErrorModel.from(error)

        #expect(model.retryAction == .retryOperation)
    }

    @Test("server 429 → retryOperation (rate limit, not daily quota)")
    func serverError429() {
        let error = NetworkError.serverError(statusCode: 429, message: "Rate limited")
        let model = AppErrorModel.from(error)

        #expect(model.retryAction == .retryOperation)
    }

    @Test("invalidResponse → retryOperation")
    func invalidResponse() {
        let error = NetworkError.invalidResponse
        let model = AppErrorModel.from(error)

        #expect(model.retryAction == .retryOperation)
    }

    @Test("decodingError → retryOperation")
    func decodingError() {
        struct Dummy: Decodable {}
        let underlying = try! JSONDecoder().decode(Dummy.self, from: Data("{}".utf8)) as? Error
            ?? NSError(domain: "test", code: 0)
        let error = NetworkError.decodingError(underlying)
        let model = AppErrorModel.from(error)

        #expect(model.retryAction == .retryOperation)
    }

    @Test("invalidURL → dismiss (configuration error, retry won't help)")
    func invalidURL() {
        let error = NetworkError.invalidURL
        let model = AppErrorModel.from(error)

        #expect(model.retryAction == .dismiss)
    }

    // MARK: - Cancellation (54.15)

    /// Regression: a cancellation surfaced as a generic "retry" error is exactly
    /// the founder-reported OOPS screen (54.5) — the CTA must be a soft dismiss,
    /// not a misleading retry, and the copy must be the intentional localized
    /// string (#56: English source "Action cancelled"), not a raw leaked system
    /// error string.
    @Test("CancellationError → dismiss with intentional copy")
    func cancellationError() {
        let model = AppErrorModel.from(CancellationError(), context: .submission)

        #expect(model.retryAction == .dismiss)
        #expect(model.title == "Action cancelled")
    }

    @Test("URLError.cancelled → dismiss with intentional copy")
    func urlErrorCancelled() {
        let model = AppErrorModel.from(URLError(.cancelled), context: .submission)

        #expect(model.retryAction == .dismiss)
        #expect(model.title == "Action cancelled")
    }

    // MARK: - Context-only factory (54.15: ContentView fallback path)

    /// Regression: ContentView's `.error` case falls back to `from(context:)`
    /// when no underlying Error was captured — it must produce the same SK
    /// copy as the error-driven fallback, never raw English.
    @Test("context-only factory produces copy per context")
    func contextOnlyFactory() {
        let contexts: [ErrorContext] = [.initialization, .submission, .recording, .general]
        for context in contexts {
            let model = AppErrorModel.from(context: context)
            #expect(!model.title.isEmpty, "title empty for \(context)")
            #expect(!model.description.isEmpty, "description empty for \(context)")
            #expect(model.retryAction == .retryOperation)
        }
    }

    // MARK: - Context-driven fallback

    @Test("initialization context fallback → retryOperation")
    func initializationContextFallback() {
        let error = NSError(domain: "unknown", code: 0)
        let model = AppErrorModel.from(error, context: .initialization)

        #expect(model.retryAction == .retryOperation)
        #expect(!model.title.isEmpty)
    }

    @Test("submission context fallback → retryOperation")
    func submissionContextFallback() {
        let error = NSError(domain: "unknown", code: 0)
        let model = AppErrorModel.from(error, context: .submission)

        #expect(model.retryAction == .retryOperation)
    }

    @Test("recording context fallback → retryOperation")
    func recordingContextFallback() {
        let error = NSError(domain: "unknown", code: 0)
        let model = AppErrorModel.from(error, context: .recording)

        #expect(model.retryAction == .retryOperation)
    }

    @Test("general context fallback → retryOperation")
    func generalContextFallback() {
        let error = NSError(domain: "unknown", code: 0)
        let model = AppErrorModel.from(error, context: .general)

        #expect(model.retryAction == .retryOperation)
    }

    // MARK: - Copy sanity (#56: English source)

    @Test("all mapped cases produce non-empty title and description")
    func allCasesHaveNonEmptyStrings() {
        let limitError = QuotaLimitError(
            error: "limit_reached",
            questionsUsed: 10,
            questionsLimit: 10,
            resetsAt: "2026-06-12T00:00:00Z",
            upgradeAvailable: true
        )
        let cases: [Error] = [
            URLError(.notConnectedToInternet),
            URLError(.timedOut),
            NetworkError.quotaLimitReached(limitError),
            NetworkError.sessionNotFound,
            NetworkError.serverError(statusCode: 500, message: "err"),
            NetworkError.serverError(statusCode: 429, message: "err"),
            NetworkError.invalidResponse,
            NetworkError.invalidURL,
        ]

        for error in cases {
            let model = AppErrorModel.from(error)
            #expect(!model.title.isEmpty, "title empty for \(error)")
            #expect(!model.description.isEmpty, "description empty for \(error)")
        }
    }
}
