//
//  NetworkServiceTests.swift
//  HangsTests
//
//  URLProtocol-stubbed unit tests for NetworkService.
//  All requests are intercepted by StubURLProtocol — no real network activity.
//
//  Deviations from the handoff spec (issue-31-handoff.md Task 2.4):
//  - "audioIntegrity" case does not exist; Content-Length mismatch throws
//    NetworkError.invalidResponse (confirmed in NetworkService.swift:495-498).
//  - extendSession 5xx throws NetworkError.invalidResponse (not .serverError),
//    because extendSession has a single guard that collapses all non-2xx cases
//    (NetworkService.swift:272-275).
//

import Foundation
@testable import Hangs
import os
import Testing

// MARK: - JSON fixtures

// Placed in a nonisolated enum so they can be referenced from @Sendable
// URLProtocol handler closures without actor-isolation warnings.

private nonisolated enum Stubs {
    static let baseURL = "http://test.invalid"

    static let dailyLimitJSON = #"""
    {
      "detail": {
        "error": "daily_limit_reached",
        "questions_used": 10,
        "questions_limit": 10,
        "resets_at": "2026-05-08T00:00:00Z",
        "upgrade_available": true
      }
    }
    """#

    static let rateLimitJSON = #"""
    {
      "error": "Rate limit exceeded: 10 per 1 minute"
    }
    """#

    static let usageInfoJSON = #"""
    {
      "user_id": "user_abc",
      "is_premium": false,
      "questions_used": 3,
      "questions_limit": 10,
      "remaining": 7,
      "resets_at": "2026-05-08T00:00:00Z",
      "subscription_status": "none",
      "credit_balance": 0
    }
    """#
}

// MARK: - NetworkServiceTests

// .serialized prevents tests running in parallel — required because
// StubURLProtocol.handler is a process-wide static.
@Suite("NetworkService — URLProtocol stubs", .serialized)
struct NetworkServiceTests {
    // MARK: Helpers

    private func makeService() -> NetworkService {
        NetworkService(baseURL: Stubs.baseURL, session: StubURLProtocol.makeSession())
    }

    // MARK: 1. 429 → quotaLimitReached (valid body)

    @Test("submitTextInput 429 with valid QuotaLimitErrorWrapper → .quotaLimitReached")
    func quotaLimitReachedValidBody() async throws {
        let service = makeService()
        StubURLProtocol.handler = { _ in
            (.make(status: 429), Data(Stubs.dailyLimitJSON.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        do {
            _ = try await service.submitTextInput(sessionId: "s1", input: "Paris", audio: false)
            Issue.record("Expected throw, got success")
        } catch let error as NetworkError {
            if case let .quotaLimitReached(detail) = error {
                #expect(detail.error == "daily_limit_reached")
                #expect(detail.questionsUsed == 10)
                #expect(detail.questionsLimit == 10)
                #expect(detail.upgradeAvailable == true)
            } else {
                Issue.record("Expected .quotaLimitReached, got \(error)")
            }
        }
    }

    // MARK: 2. 429 with malformed body → .serverError(429, "Rate limited")

    @Test("submitTextInput 429 with malformed body → .serverError(429, …)")
    func dailyLimitMalformedBody() async throws {
        let service = makeService()
        StubURLProtocol.handler = { _ in
            (.make(status: 429), Data("garbage".utf8))
        }
        defer { StubURLProtocol.handler = nil }

        do {
            _ = try await service.submitTextInput(sessionId: "s1", input: "Paris", audio: false)
            Issue.record("Expected throw, got success")
        } catch let error as NetworkError {
            if case let .serverError(code, _) = error {
                #expect(code == 429)
            } else {
                Issue.record("Expected .serverError(429, …), got \(error)")
            }
        }
    }

    // MARK: 3. downloadAudio Content-Length mismatch → .invalidResponse

    @Test("downloadAudio with Content-Length mismatch → .invalidResponse")
    func downloadAudioContentLengthMismatch() async throws {
        let service = makeService()
        let body = Data(repeating: 0xAA, count: 100)
        let mismatchedLength = body.count + 10 // 110
        StubURLProtocol.handler = { _ in
            (.make(status: 200, headers: ["Content-Length": "\(mismatchedLength)"]), body)
        }
        defer { StubURLProtocol.handler = nil }

        do {
            _ = try await service.downloadAudio(from: "/audio/test.mp3")
            Issue.record("Expected .invalidResponse, got success")
        } catch let error as NetworkError {
            guard case .invalidResponse = error else {
                Issue.record("Expected .invalidResponse, got \(error)"); return
            }
        }
    }

    // MARK: 4. downloadAudio happy path (no Content-Length header)

    @Test("downloadAudio happy path with no Content-Length → returns body data")
    func downloadAudioHappyPath() async throws {
        let service = makeService()
        let expectedData = Data("fake-audio-bytes".utf8)
        StubURLProtocol.handler = { _ in (.make(status: 200), expectedData) }
        defer { StubURLProtocol.handler = nil }

        let result = try await service.downloadAudio(from: "/audio/test.mp3")
        #expect(result == expectedData)
    }

    // MARK: 5. extendSession happy path

    @Test("extendSession 200 → completes without throw")
    func extendSessionHappyPath() async throws {
        let service = makeService()
        StubURLProtocol.handler = { _ in (.make(status: 200), Data()) }
        defer { StubURLProtocol.handler = nil }

        try await service.extendSession(sessionId: "s1", minutes: 30)
    }

    // MARK: 6. extendSession 5xx → .invalidResponse

    //
    // extendSession has a single guard over the 2xx range and throws
    // .invalidResponse for all non-2xx, including 5xx. The handoff spec
    // incorrectly stated .serverError — see NetworkService.swift:272-275.

    @Test("extendSession 500 → .invalidResponse")
    func extendSessionServerError() async throws {
        let service = makeService()
        StubURLProtocol.handler = { _ in (.make(status: 500), Data()) }
        defer { StubURLProtocol.handler = nil }

        do {
            try await service.extendSession(sessionId: "s1", minutes: 30)
            Issue.record("Expected throw, got success")
        } catch let error as NetworkError {
            guard case .invalidResponse = error else {
                Issue.record("Expected .invalidResponse, got \(error)"); return
            }
        }
    }

    // MARK: 7. rateQuestion happy path

    @Test("rateQuestion 200 → completes without throw")
    func rateQuestionHappyPath() async throws {
        let service = makeService()
        StubURLProtocol.handler = { _ in (.make(status: 200), Data()) }
        defer { StubURLProtocol.handler = nil }

        try await service.rateQuestion(sessionId: "s1", rating: 5)
    }

    // MARK: 8. flagQuestion happy path — verify reason in request body

    /// URLSession sometimes moves httpBody to httpBodyStream before handing
    /// the request to URLProtocol. Reads whichever is present.
    private nonisolated func readBody(from request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let n = stream.read(buffer, maxLength: bufSize)
            guard n > 0 else { break }
            data.append(buffer, count: n)
        }
        return data.isEmpty ? nil : data
    }

    @Test("flagQuestion 200 with reason → body contains 'reason' field")
    func flagQuestionWithReason() async throws {
        let service = makeService()

        // OSAllocatedUnfairLock<URLRequest?> is Sendable — safe to capture in
        // the @Sendable URLProtocol handler without nonisolated(unsafe).
        let captured = OSAllocatedUnfairLock<URLRequest?>(initialState: nil)

        StubURLProtocol.handler = { req in
            captured.withLock { $0 = req }
            return (.make(status: 200), Data())
        }
        defer { StubURLProtocol.handler = nil }

        try await service.flagQuestion(sessionId: "s1", reason: "incorrect_answer")

        let capturedRequest = try #require(
            captured.withLock { $0 },
            "Expected request to be captured by StubURLProtocol"
        )
        let bodyData = try #require(
            readBody(from: capturedRequest),
            "Expected non-nil body in flagQuestion request"
        )
        let decoded = try JSONSerialization.jsonObject(with: bodyData) as? [String: String]
        #expect(decoded?["reason"] == "incorrect_answer")
    }

    // MARK: 9. getUsage happy path

    @Test("getUsage 200 with valid JSON → returns decoded UsageInfo")
    func getUsageHappyPath() async throws {
        let service = makeService()
        let captured = OSAllocatedUnfairLock<URLRequest?>(initialState: nil)
        StubURLProtocol.handler = { req in
            captured.withLock { $0 = req }
            return (.make(status: 200), Data(Stubs.usageInfoJSON.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        let usage = try await service.getUsage()
        // Identity must be bearer-derived server-side — the client-suppliable
        // /usage/{id} path read a different account than purchases landed on
        // (#96 P1), so the path itself is the regression surface.
        let request = try #require(captured.withLock { $0 })
        #expect(request.url?.path.hasSuffix("/usage/me") == true)
        #expect(usage.userId == "user_abc")
        #expect(usage.questionsUsed == 3)
        #expect(usage.questionsLimit == 10)
        #expect(usage.isPremium == false)
        #expect(usage.resetsAt == "2026-05-08T00:00:00Z")
    }

    // MARK: 10. getUsage decode failure

    @Test("getUsage 200 with malformed JSON → throws DecodingError")
    func getUsageDecodeFailure() async throws {
        let service = makeService()
        StubURLProtocol.handler = { _ in (.make(status: 200), Data("not json".utf8)) }
        defer { StubURLProtocol.handler = nil }

        // getUsage propagates JSONDecoder errors directly as DecodingError,
        // NOT wrapped in NetworkError.decodingError.
        await #expect(throws: (any Error).self) {
            _ = try await service.getUsage()
        }
    }

    // MARK: 11. Bearer attached + 401 → single-flight refresh → retry (#60.8)

    //
    // With an AuthService wired, every request carries `Authorization: Bearer
    // <access>`. A 401 must trigger exactly one refresh and one retry that
    // carries the *new* bearer. Uses a stub AuthService so this isolates
    // NetworkService's retry logic from the real bootstrap/refresh flow.

    @Test("401 → refresh → retry carries new bearer and succeeds")
    func unauthorizedTriggersRefreshAndRetry() async throws {
        let auth = StubAuthService(initialToken: "stale", refreshedToken: "fresh")
        let service = NetworkService(
            baseURL: Stubs.baseURL,
            session: StubURLProtocol.makeSession(),
            authService: auth
        )

        // Record the bearer seen on each request; 401 for "stale", 200 for "fresh".
        let seen = OSAllocatedUnfairLock<[String]>(initialState: [])
        StubURLProtocol.handler = { req in
            let bearer = req.value(forHTTPHeaderField: "Authorization") ?? ""
            seen.withLock { $0.append(bearer) }
            if bearer == "Bearer fresh" {
                return (.make(status: 200), Data(Stubs.usageInfoJSON.utf8))
            }
            return (.make(status: 401), Data())
        }
        defer { StubURLProtocol.handler = nil }

        let usage = try await service.getUsage()
        #expect(usage.userId == "user_abc")

        let bearers = seen.withLock { $0 }
        #expect(bearers == ["Bearer stale", "Bearer fresh"])
        let refreshes = await auth.refreshCallCount()
        #expect(refreshes == 1)
    }

    // MARK: 12. No authService → no Authorization header (grace path)

    @Test("no authService → request carries no Authorization header")
    func noAuthServiceSendsNoBearer() async throws {
        let service = makeService() // built without authService
        let captured = OSAllocatedUnfairLock<URLRequest?>(initialState: nil)
        StubURLProtocol.handler = { req in
            captured.withLock { $0 = req }
            return (.make(status: 200), Data(Stubs.usageInfoJSON.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        _ = try await service.getUsage()
        let request = try #require(captured.withLock { $0 })
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // MARK: 13. downloadAudio carries the bearer

    //
    // Regression guard for the silent question-TTS outage: the audio routes are
    // auth-gated (require_auth_or_grace) and hard-401 with the grace flag off,
    // so a bearer-less download means no question audio ever plays. downloadAudio
    // must go through the same authorized path as every other endpoint.

    @Test("downloadAudio attaches Authorization bearer")
    func downloadAudioAttachesBearer() async throws {
        let auth = StubAuthService(initialToken: "tok", refreshedToken: "fresh")
        let service = NetworkService(
            baseURL: Stubs.baseURL,
            session: StubURLProtocol.makeSession(),
            authService: auth
        )
        let captured = OSAllocatedUnfairLock<URLRequest?>(initialState: nil)
        StubURLProtocol.handler = { req in
            captured.withLock { $0 = req }
            return (.make(status: 200), Data("fake-audio-bytes".utf8))
        }
        defer { StubURLProtocol.handler = nil }

        _ = try await service.downloadAudio(from: "/api/v1/sessions/s1/question/audio")

        let request = try #require(captured.withLock { $0 })
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    // MARK: 14. downloadAudio 401 → refresh → retry (same seam as other endpoints)

    @Test("downloadAudio 401 → refresh → retry carries new bearer and succeeds")
    func downloadAudioRefreshesOn401() async throws {
        let auth = StubAuthService(initialToken: "stale", refreshedToken: "fresh")
        let service = NetworkService(
            baseURL: Stubs.baseURL,
            session: StubURLProtocol.makeSession(),
            authService: auth
        )
        let expectedData = Data("fake-audio-bytes".utf8)
        StubURLProtocol.handler = { req in
            if req.value(forHTTPHeaderField: "Authorization") == "Bearer fresh" {
                return (.make(status: 200), expectedData)
            }
            return (.make(status: 401), Data())
        }
        defer { StubURLProtocol.handler = nil }

        let result = try await service.downloadAudio(from: "/api/v1/sessions/s1/question/audio")
        #expect(result == expectedData)
        let refreshes = await auth.refreshCallCount()
        #expect(refreshes == 1)
    }

    // MARK: 15. createSession 429 + quota body → .quotaLimitReached

    //
    // createSession previously had NO 429 handling at all — a real 429 there
    // threw .invalidResponse unconditionally. #112 decision 2: routing it
    // through the generic gives it the same body-discriminated parse as
    // startQuiz/submitTextInput/submitVoiceAnswer. Pins that a quota-shaped
    // 429 body now correctly maps to the paywall path here too.

    @Test("createSession 429 with valid QuotaLimitErrorWrapper → .quotaLimitReached")
    func createSessionQuotaLimitReached() async throws {
        let service = makeService()
        StubURLProtocol.handler = { _ in
            (.make(status: 429), Data(Stubs.dailyLimitJSON.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        do {
            _ = try await service.createSession()
            Issue.record("Expected throw, got success")
        } catch let error as NetworkError {
            guard case .quotaLimitReached = error else {
                Issue.record("Expected .quotaLimitReached, got \(error)")
                return
            }
        }
    }

    // MARK: 16. createSession 429 + non-quota rate-limit body → .serverError(429, …), NOT .quotaLimitReached

    //
    // createSession's only real-world 429 is the @limiter.limit("10/minute")
    // request rate-limit (sessions.py:75) — its body never carries a
    // QuotaLimitError wrapper. Guards against a false-positive paywall
    // trigger: a plain rate-limit body must fall through to .serverError,
    // never .quotaLimitReached.

    @Test("createSession 429 with non-quota rate-limit body → .serverError(429, …), not .quotaLimitReached")
    func createSessionRateLimitDoesNotFalseTriggerPaywall() async throws {
        let service = makeService()
        StubURLProtocol.handler = { _ in
            (.make(status: 429), Data(Stubs.rateLimitJSON.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        do {
            _ = try await service.createSession()
            Issue.record("Expected throw, got success")
        } catch let error as NetworkError {
            if case let .serverError(code, _) = error {
                #expect(code == 429)
            } else {
                Issue.record("Expected .serverError(429, …), got \(error)")
            }
        }
    }
}

// MARK: - StubAuthService

/// Deterministic AuthService for NetworkService retry tests: hands out a fixed
/// access token, then a fixed refreshed token, counting refresh calls.
private actor StubAuthService: AuthServiceProtocol {
    private let initialToken: String
    private let refreshedToken: String
    private var refreshes = 0

    init(initialToken: String, refreshedToken: String) {
        self.initialToken = initialToken
        self.refreshedToken = refreshedToken
    }

    func accessToken() async -> String? { initialToken }

    func refreshedAccessToken(replacing _: String) async -> String? {
        refreshes += 1
        return refreshedToken
    }

    func refreshCallCount() -> Int { refreshes }
}
