//
//  AuthServiceTests.swift
//  HangsTests
//
//  URLProtocol-stubbed unit tests for AuthService (issue #60, task 60.9).
//  Covers: Keychain store/retrieve (mocked), bootstrap-on-first-launch,
//  401 → single-flight refresh, and re-bootstrap on refresh failure.
//  No real network and no real Keychain — StubURLProtocol + MockTokenStore.
//

import Foundation
import os
import Testing
@testable import Hangs

// MARK: - JSON fixtures

private nonisolated enum AuthStubs {
    static let baseURL = "http://test.invalid"

    static func tokenJSON(access: String, refresh: String, anon: String) -> String {
        #"""
        {
          "access_token": "\#(access)",
          "refresh_token": "\#(refresh)",
          "token_type": "bearer",
          "expires_in": 900,
          "anon_id": "\#(anon)"
        }
        """#
    }
}

// MARK: - AuthStubURLProtocol
//
// A dedicated URLProtocol with its OWN process-wide handler, separate from
// NetworkServiceTests' StubURLProtocol. Swift Testing's `.serialized` only
// serializes tests *within* a suite — separate suites still run in parallel, so
// sharing one static handler across both suites races them (NSURLError -1011).
// Independent statics let the two suites run concurrently and safely.

final class AuthStubURLProtocol: URLProtocol, @unchecked Sendable {
    private nonisolated static let handlerLock = OSAllocatedUnfairLock<
        ((@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    )>(initialState: nil)

    nonisolated static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { handlerLock.withLock { $0 } }
        set { handlerLock.withLock { $0 = newValue } }
    }

    nonisolated override class func canInit(with request: URLRequest) -> Bool { true }
    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    nonisolated override func startLoading() {
        // Run the handler off the URL-loading thread. The single-flight test's
        // handler blocks (Thread.sleep) to hold the refresh open; doing that on
        // the loading thread would starve another suite's concurrent request
        // sharing the loading-thread pool (observed as NSURLError -1011).
        let request = self.request
        DispatchQueue.global(qos: .userInitiated).async {
            guard let handler = Self.handler else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            do {
                let (response, data) = try handler(request)
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data)
                self.client?.urlProtocolDidFinishLoading(self)
            } catch {
                self.client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    nonisolated override func stopLoading() {}

    static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [AuthStubURLProtocol.self]
        return URLSession(configuration: cfg)
    }
}

// MARK: - MockTokenStore (in-memory, stands in for the Keychain)

private nonisolated final class MockTokenStore: TokenStore, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<AuthTokens?>(initialState: nil)

    init(seed: AuthTokens? = nil) {
        lock.withLock { $0 = seed }
    }

    func load() -> AuthTokens? { lock.withLock { $0 } }
    func save(_ tokens: AuthTokens) { lock.withLock { $0 = tokens } }
    func clear() { lock.withLock { $0 = nil } }
}

// MARK: - AuthServiceTests

@Suite("AuthService — URLProtocol stubs", .serialized)
struct AuthServiceTests {

    private func makeService(store: TokenStore) -> AuthService {
        AuthService(
            baseURL: AuthStubs.baseURL,
            session: AuthStubURLProtocol.makeSession(),
            store: store
        )
    }

    // MARK: 1. Bootstrap on first launch (empty store)

    @Test("first launch with empty store bootstraps and persists the pair")
    func bootstrapOnFirstLaunch() async throws {
        let store = MockTokenStore()
        let service = makeService(store: store)

        AuthStubURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/v1/auth/anon-bootstrap")
            return (.make(status: 200), Data(AuthStubs.tokenJSON(access: "a1", refresh: "r1", anon: "anon-1").utf8))
        }
        defer { AuthStubURLProtocol.handler = nil }

        let token = await service.accessToken()
        #expect(token == "a1")
        // Persisted to the (mock) Keychain for the next launch.
        #expect(store.load()?.accessToken == "a1")
        #expect(store.load()?.refreshToken == "r1")
        #expect(store.load()?.anonId == "anon-1")
    }

    // MARK: 2. Stored token is reused without a network call

    @Test("existing stored token is returned without bootstrapping")
    func reuseStoredTokenNoNetwork() async throws {
        let seeded = AuthTokens(accessToken: "stored", refreshToken: "r", anonId: "anon")
        let store = MockTokenStore(seed: seeded)
        let service = makeService(store: store)

        // Any network hit would fail the test (no handler set → badServerResponse).
        AuthStubURLProtocol.handler = { _ in
            Issue.record("AuthService must not hit the network when a token is stored")
            return (.make(status: 500), Data())
        }
        defer { AuthStubURLProtocol.handler = nil }

        let token = await service.accessToken()
        #expect(token == "stored")
    }

    // MARK: 3. Bootstrap unavailable (503) → nil (grace path)

    @Test("bootstrap 503 → nil so the caller falls back to the grace path")
    func bootstrapUnavailableReturnsNil() async throws {
        let store = MockTokenStore()
        let service = makeService(store: store)

        AuthStubURLProtocol.handler = { _ in (.make(status: 503), Data()) }
        defer { AuthStubURLProtocol.handler = nil }

        let token = await service.accessToken()
        #expect(token == nil)
        #expect(store.load() == nil)
    }

    // MARK: 4. Refresh rotates the pair

    @Test("401 refresh rotates the token pair and persists the new one")
    func refreshRotatesPair() async throws {
        let seeded = AuthTokens(accessToken: "old", refreshToken: "r-old", anonId: "anon-1")
        let store = MockTokenStore(seed: seeded)
        let service = makeService(store: store)
        // Warm the in-memory cache the way a normal request would.
        _ = await service.accessToken()

        AuthStubURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/v1/auth/refresh")
            return (.make(status: 200), Data(AuthStubs.tokenJSON(access: "new", refresh: "r-new", anon: "anon-1").utf8))
        }
        defer { AuthStubURLProtocol.handler = nil }

        let token = await service.refreshedAccessToken(replacing: "old")
        #expect(token == "new")
        #expect(store.load()?.refreshToken == "r-new")
    }

    // MARK: 5. Re-bootstrap when the refresh token is rejected

    @Test("refresh 401 → re-bootstrap a fresh identity")
    func reBootstrapOnRefreshFailure() async throws {
        let seeded = AuthTokens(accessToken: "old", refreshToken: "r-revoked", anonId: "anon-1")
        let store = MockTokenStore(seed: seeded)
        let service = makeService(store: store)
        _ = await service.accessToken()

        AuthStubURLProtocol.handler = { req in
            if req.url?.path == "/api/v1/auth/refresh" {
                return (.make(status: 401), Data())  // family revoked
            }
            // Re-bootstrap path
            #expect(req.url?.path == "/api/v1/auth/anon-bootstrap")
            return (.make(status: 200), Data(AuthStubs.tokenJSON(access: "fresh", refresh: "r-fresh", anon: "anon-2").utf8))
        }
        defer { AuthStubURLProtocol.handler = nil }

        let token = await service.refreshedAccessToken(replacing: "old")
        #expect(token == "fresh")
        #expect(store.load()?.anonId == "anon-2")
    }

    // MARK: 5b. Transient refresh failure must NOT orphan a signed-in account (I1)

    /// WHY: a transient 5xx during a backend deploy previously fell through to a
    /// fresh anon bootstrap, silently orphaning an Apple-signed-in user's account.
    /// The stored tokens MUST be preserved and the caller must get a retryable nil.
    @Test("transient 5xx on a signed-in refresh keeps stored tokens and does NOT bootstrap")
    func transientRefreshFailureKeepsSignedInTokens() async throws {
        let seeded = AuthTokens(
            accessToken: "acc", refreshToken: "r-old", anonId: "users-1",
            accountName: "Jane", accountEmail: "jane@example.com", appleUserId: "apple-1"
        )
        let store = MockTokenStore(seed: seeded)
        let service = makeService(store: store)
        _ = await service.accessToken()  // warm cache

        let bootstrapCalled = OSAllocatedUnfairLock<Bool>(initialState: false)
        AuthStubURLProtocol.handler = { req in
            if req.url?.path == "/api/v1/auth/refresh" {
                return (.make(status: 503), Data())  // transient outage during a deploy
            }
            if req.url?.path == "/api/v1/auth/anon-bootstrap" {
                bootstrapCalled.withLock { $0 = true }
            }
            return (.make(status: 200), Data(AuthStubs.tokenJSON(access: "orphan", refresh: "x", anon: "y").utf8))
        }
        defer { AuthStubURLProtocol.handler = nil }

        let token = await service.refreshedAccessToken(replacing: "acc")
        #expect(token == nil, "transient failure must surface as retryable nil, not a new anon token")
        #expect(!bootstrapCalled.withLock { $0 }, "must NOT mint a fresh anon on a transient error")
        // The Apple-linked tokens are preserved for a later retry.
        #expect(store.load()?.appleUserId == "apple-1")
        #expect(store.load()?.accessToken == "acc")
    }

    // MARK: 5c. Real 401 on a signed-in refresh drops to anon and notifies UI (I1/I7)

    /// WHY: a genuine refresh 401 (revoked/expired) on an Apple-linked session is a
    /// real sign-out. It must drop to a fresh anon AND post the notification so the
    /// UI (SettingsView) can reload its account state.
    @Test("real 401 on a signed-in refresh drops to anon and posts the session-dropped notification")
    func realRefreshRejectionDropsSignedInAndNotifies() async throws {
        let seeded = AuthTokens(
            accessToken: "acc", refreshToken: "r-revoked", anonId: "users-1",
            accountName: "Jane", accountEmail: nil, appleUserId: "apple-1"
        )
        let store = MockTokenStore(seed: seeded)
        let service = makeService(store: store)
        _ = await service.accessToken()  // warm cache

        let notified = OSAllocatedUnfairLock<Bool>(initialState: false)
        let observer = NotificationCenter.default.addObserver(
            forName: .authSignedInSessionDropped, object: nil, queue: nil
        ) { _ in
            notified.withLock { $0 = true }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        AuthStubURLProtocol.handler = { req in
            if req.url?.path == "/api/v1/auth/refresh" {
                return (.make(status: 401), Data())  // refresh token genuinely rejected
            }
            #expect(req.url?.path == "/api/v1/auth/anon-bootstrap")
            return (.make(status: 200), Data(AuthStubs.tokenJSON(access: "fresh-anon", refresh: "r-fresh", anon: "anon-2").utf8))
        }
        defer { AuthStubURLProtocol.handler = nil }

        let token = await service.refreshedAccessToken(replacing: "acc")
        #expect(token == "fresh-anon", "a genuine 401 must fall through to a fresh anon identity")
        #expect(store.load()?.appleUserId == nil, "the dropped account linkage must be cleared")
        #expect(store.load()?.accessToken == "fresh-anon")
        #expect(notified.withLock { $0 }, "UI must be notified so it can reload account state (I7)")
    }

    // MARK: 6. Single-flight refresh — concurrent 401s share one refresh

    @Test("concurrent refreshes for the same stale token fire only one refresh")
    func singleFlightRefresh() async throws {
        let seeded = AuthTokens(accessToken: "old", refreshToken: "r-old", anonId: "anon-1")
        let store = MockTokenStore(seed: seeded)
        let service = makeService(store: store)
        _ = await service.accessToken()

        let refreshCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        AuthStubURLProtocol.handler = { req in
            if req.url?.path == "/api/v1/auth/refresh" {
                refreshCount.withLock { $0 += 1 }
                // Hold the request open briefly so concurrent callers collide on
                // the in-flight refresh task (single-flight window).
                Thread.sleep(forTimeInterval: 0.1)
                return (.make(status: 200), Data(AuthStubs.tokenJSON(access: "new", refresh: "r-new", anon: "anon-1").utf8))
            }
            return (.make(status: 500), Data())
        }
        defer { AuthStubURLProtocol.handler = nil }

        // Ten concurrent callers, all holding the same stale "old" token.
        let tokens = await withTaskGroup(of: String?.self) { group in
            for _ in 0..<10 {
                group.addTask { await service.refreshedAccessToken(replacing: "old") }
            }
            var results: [String?] = []
            for await t in group { results.append(t) }
            return results
        }

        #expect(tokens.allSatisfy { $0 == "new" })
        #expect(refreshCount.withLock { $0 } == 1)
    }
}
