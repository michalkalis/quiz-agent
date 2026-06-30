//
//  AppleAuthTests.swift
//  HangsTests
//
//  Unit tests for Apple Sign in with Apple auth logic (issue #61, tasks 61.6/61.7/61.8).
//
//  What is tested here:
//   1. Nonce encoding — asserts the exact F6 transform: base64url-nopad(SHA256(rawNonce.utf8)).
//      This is the #1 bug in the SIWA flow: sending hex or raw nonce causes 401 on every sign-in.
//   2. completeAppleSignIn — calls /auth/apple with the anon bearer and swaps stored tokens to
//      account tokens.
//   3. deleteAccount — calls DELETE /auth/me and clears stored tokens, then re-bootstraps anon.
//   4. credentialRevokedNotification — drops to a fresh anon when the notification fires.
//
//  Real SIWA sheet cannot run in unit tests (requires a device + entitlement) — we test the
//  AuthService logic with mock data, not the system sign-in sheet.
//
//  Uses a dedicated AppleStubURLProtocol (independent of AuthStubURLProtocol used in
//  AuthServiceTests). Swift Testing runs suites in parallel; sharing a static handler
//  across suites races them (NSURLError -1011). Each auth suite must own its protocol.
//

import AuthenticationServices
import CryptoKit
import Foundation
import os
import Testing
@testable import Hangs

// MARK: - AppleStubURLProtocol

// Dedicated URLProtocol for the Apple-auth test suite.
// Isolated static handler + session so it never races AuthServiceTests or AuthAttestTests.

final class AppleStubURLProtocol: URLProtocol, @unchecked Sendable {
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
        cfg.protocolClasses = [AppleStubURLProtocol.self]
        return URLSession(configuration: cfg)
    }
}

// MARK: - AppleTestTokenStore

nonisolated final class AppleTestTokenStore: TokenStore, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<AuthTokens?>(initialState: nil)

    init(seed: AuthTokens? = nil) {
        lock.withLock { $0 = seed }
    }

    func load() -> AuthTokens? { lock.withLock { $0 } }
    func save(_ tokens: AuthTokens) { lock.withLock { $0 = tokens } }
    func clear() { lock.withLock { $0 = nil } }
}

// MARK: - Fixtures

private nonisolated enum AppleAuthStubs {
    static let baseURL = "http://apple-auth-test.invalid"

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
// HTTPURLResponse.make(status:) is provided by Support/StubURLProtocol.swift (shared test target helper).

// MARK: - AppleAuthTests

@Suite("Apple Auth — nonce + credential flow", .serialized)
struct AppleAuthTests {

    // MARK: - 1. Nonce encoding (F6)

    /// The nonce sent to Apple MUST be base64url-nopad(SHA256(rawNonce.utf8)).
    /// NOT hex (64-char hexdigest). NOT the raw nonce itself.
    /// The backend verifier (app/auth/apple.py::expected_nonce_claim) computes the same
    /// transform on the `raw_nonce` string it receives, so both sides must agree exactly.
    @Test("nonce sent to Apple is base64url-nopad(SHA256(rawNonce.utf8)) — NOT hex, NOT raw (F6)")
    func nonceIsBase64URLNoPadSHA256() {
        let rawNonce = "test-raw-nonce-for-f6-verification"
        let service = makeService(store: AppleTestTokenStore())
        let hashed = service.hashedNonce(for: rawNonce)

        // Compute the expected value independently.
        let data = Data(rawNonce.utf8)
        let digest = SHA256.hash(data: data)
        let expected = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        #expect(hashed == expected, "hashedNonce must equal base64url-nopad(SHA256(rawNonce.utf8))")
        #expect(!hashed.contains("="), "No padding characters allowed (nopad)")

        // Explicitly assert NOT hex — hex SHA256 is 64 lowercase chars; base64url of 32 bytes is 43.
        let hexDigest = Data(digest).map { String(format: "%02hhx", $0) }.joined()
        #expect(hashed != hexDigest, "Must NOT be hex-encoded — that is the F6 footgun")
        #expect(hashed != rawNonce, "Must NOT be the raw nonce")
        // Length sanity: SHA256 is 32 bytes -> base64url-nopad is 43 chars.
        #expect(hashed.count == 43, "base64url-nopad of 32 bytes must be 43 characters")
    }

    // MARK: - 2. Apple credential -> /auth/apple with anon bearer, swaps tokens

    /// A successful credential flow POSTs to /auth/apple carrying the anon bearer
    /// (so the backend can merge anon usage per F3) and then replaces the stored
    /// anon tokens with the returned account tokens.
    @Test("completeAppleSignIn POSTs to /auth/apple with anon bearer and swaps stored tokens")
    func appleSignInCallsEndpointWithAnonBearerAndSwapsTokens() async throws {
        let anonTokens = AuthTokens(accessToken: "anon-access", refreshToken: "anon-refresh", anonId: "anon-123")
        let store = AppleTestTokenStore(seed: anonTokens)
        let service = makeService(store: store)
        _ = await service.accessToken()  // warm in-memory cache

        let receivedBearers = OSAllocatedUnfairLock<[String]>(initialState: [])

        AppleStubURLProtocol.handler = { req in
            if req.url?.path == "/api/v1/auth/apple" {
                let bearer = req.value(forHTTPHeaderField: "Authorization") ?? ""
                receivedBearers.withLock { $0.append(bearer) }
                return (
                    .make(status: 200),
                    Data(AppleAuthStubs.tokenJSON(access: "account-access", refresh: "account-refresh", anon: "users-id-1").utf8)
                )
            }
            return (.make(status: 500), Data())
        }
        defer { AppleStubURLProtocol.handler = nil }

        let result = await service.completeAppleSignIn(
            identityToken: "mock-id-token",
            authorizationCode: "mock-auth-code",
            rawNonce: "test-raw-nonce",
            user: "apple-user-123",
            fullName: "Test User",
            email: "test@privaterelay.appleid.com"
        )

        #expect(result != nil, "Sign-in must return new tokens on success")
        #expect(result?.accessToken == "account-access")
        #expect(result?.anonId == "users-id-1", "anonId is now users.id after Apple sign-in")
        #expect(result?.appleUserId == "apple-user-123")
        #expect(result?.accountName == "Test User")
        #expect(result?.accountEmail == "test@privaterelay.appleid.com")
        // The anon bearer must have been sent so the backend can merge usage (F3).
        #expect(
            receivedBearers.withLock { $0.first } == "Bearer anon-access",
            "Must send current anon bearer to /auth/apple"
        )
        // Tokens persisted in the (mock) Keychain.
        #expect(store.load()?.accessToken == "account-access")
        #expect(store.load()?.appleUserId == "apple-user-123")
    }

    // MARK: - 3. Delete account -> calls DELETE /auth/me -> clears tokens

    /// After DELETE /auth/me succeeds, stored account tokens are cleared and a fresh
    /// anon identity is bootstrapped. The caller (SettingsView) should treat this as
    /// "signed out to anon" and refresh its displayed state.
    @Test("deleteAccount calls DELETE /auth/me, clears account tokens, and re-bootstraps anon")
    func deleteAccountClearsTokensAndReBootstrapsAnon() async throws {
        let accountTokens = AuthTokens(
            accessToken: "account-access",
            refreshToken: "account-refresh",
            anonId: "users-id-1",
            accountName: "Test User",
            accountEmail: "test@example.com",
            appleUserId: "apple-user-123"
        )
        let store = AppleTestTokenStore(seed: accountTokens)
        let service = makeService(store: store)
        _ = await service.accessToken()  // warm cache

        let deleteCalled = OSAllocatedUnfairLock<Bool>(initialState: false)

        AppleStubURLProtocol.handler = { req in
            if req.url?.path == "/api/v1/auth/me" && req.httpMethod == "DELETE" {
                deleteCalled.withLock { $0 = true }
                return (.make(status: 204), Data())
            }
            if req.url?.path == "/api/v1/auth/anon-bootstrap" {
                return (
                    .make(status: 200),
                    Data(AppleAuthStubs.tokenJSON(access: "fresh-anon", refresh: "fresh-refresh", anon: "new-anon-id").utf8)
                )
            }
            return (.make(status: 500), Data())
        }
        defer { AppleStubURLProtocol.handler = nil }

        try await service.deleteAccount()

        #expect(deleteCalled.withLock { $0 }, "DELETE /auth/me must be called")
        // After deletion, stored tokens are fresh anon (no account fields).
        let stored = store.load()
        #expect(stored?.appleUserId == nil, "appleUserId must be cleared after delete")
        #expect(stored?.accountName == nil, "accountName must be cleared after delete")
        #expect(stored?.accessToken == "fresh-anon", "Fresh anon access token must be stored")
    }

    // MARK: - 4. credentialRevokedNotification -> re-bootstrap anon

    /// When Apple sends `credentialRevokedNotification` (user revokes the app in Settings),
    /// the auth service drops stored account tokens and re-bootstraps a fresh anonymous identity.
    @Test("credentialRevokedNotification re-bootstraps a fresh anon identity")
    func credentialRevokedNotificationReBootstrapsAnon() async throws {
        let accountTokens = AuthTokens(
            accessToken: "account-access",
            refreshToken: "account-refresh",
            anonId: "users-id-1",
            accountName: "Test User",
            accountEmail: nil,
            appleUserId: "apple-user-123"
        )
        let store = AppleTestTokenStore(seed: accountTokens)
        let service = makeService(store: store)
        _ = await service.accessToken()  // warm cache

        AppleStubURLProtocol.handler = { req in
            if req.url?.path == "/api/v1/auth/anon-bootstrap" {
                return (
                    .make(status: 200),
                    Data(AppleAuthStubs.tokenJSON(access: "fresh-anon-after-revoke", refresh: "fresh-r2", anon: "anon-999").utf8)
                )
            }
            return (.make(status: 500), Data())
        }
        defer { AppleStubURLProtocol.handler = nil }

        // Wire up the revocation observer (normally called from AppState.init).
        await service.setupAppleCredentialObservation()

        // Post the notification that Apple sends when the user revokes access.
        NotificationCenter.default.post(
            name: ASAuthorizationAppleIDProvider.credentialRevokedNotification,
            object: nil
        )

        // Allow the async observer chain (Notification -> Task -> actor method) to complete.
        try await Task.sleep(nanoseconds: 300_000_000)  // 300ms

        let stored = store.load()
        #expect(stored?.appleUserId == nil, "appleUserId must be cleared after revocation")
        #expect(stored?.accessToken == "fresh-anon-after-revoke", "Fresh anon tokens must replace account tokens")
    }

    // MARK: - Helpers

    private func makeService(store: TokenStore) -> AuthService {
        AuthService(
            baseURL: AppleAuthStubs.baseURL,
            session: AppleStubURLProtocol.makeSession(),
            store: store
        )
    }
}
