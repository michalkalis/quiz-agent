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
//   5. #78 account-field merge matrix — live credential / server-decoded / stored precedence,
//      on both completeAppleSignIn and the routine refresh path; a non-nil stored name/email
//      must never be clobbered with nil.
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

    nonisolated override init(
        request: URLRequest,
        cachedResponse: CachedURLResponse?,
        client: (any URLProtocolClient)?
    ) {
        super.init(request: request, cachedResponse: cachedResponse, client: client)
    }

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
        tokenJSON(access: access, refresh: refresh, anon: anon, fullName: nil, email: nil)
    }

    /// #78: `fullName`/`email` are the new server-decoded account fields
    /// `/auth/apple` and `/auth/refresh` may now include. Optional so existing
    /// call sites (anon-bootstrap, all pre-#78 tests) are unaffected.
    static func tokenJSON(access: String, refresh: String, anon: String, fullName: String?, email: String?) -> String {
        let fullNameField = fullName.map { "\"\($0)\"" } ?? "null"
        let emailField = email.map { "\"\($0)\"" } ?? "null"
        return #"""
        {
          "access_token": "\#(access)",
          "refresh_token": "\#(refresh)",
          "token_type": "bearer",
          "expires_in": 900,
          "anon_id": "\#(anon)",
          "full_name": \#(fullNameField),
          "email": \#(emailField)
        }
        """#
    }
}
// HTTPURLResponse.make(status:) is provided by Support/StubURLProtocol.swift (shared test target helper).

// MARK: - AppleAuthTests

@Suite("Apple Auth — nonce + credential flow", .serialized)
struct AppleAuthTests {

    // MARK: - 0. Raw nonce generation (#91 item 1)

    /// generateRawNonce must yield a fresh 64-char lowercase-hex string every call.
    /// The RNG-failure branch (SecRandomCopyBytes != errSecSuccess) aborts via
    /// fatalError and is not unit-testable without wrapping the syscall — this
    /// sanity test pins the success contract the SIWA flow depends on instead.
    @Test("raw nonce is 64-char lowercase hex and unique per call")
    func rawNonceIsFreshHex() {
        let service = makeService(store: AppleTestTokenStore())
        let a = service.generateRawNonce()
        let b = service.generateRawNonce()

        #expect(a.count == 64, "32 random bytes hex-encode to 64 chars")
        #expect(a.allSatisfy { "0123456789abcdef".contains($0) }, "lowercase hex only")
        #expect(a != b, "two calls must never repeat")
        #expect(a != String(repeating: "0", count: 64), "all-zero output means the RNG guard failed")
    }

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

    // MARK: - 5. #78 account-field merge matrix
    //
    // Apple only supplies fullName/email on the FIRST authorization of an Apple ID
    // with the app — every later sign-in (and every token refresh) gets nil from
    // Apple, and the backend may or may not echo the durable value back. Before
    // #78 the client rebuilt AuthTokens straight from whatever arrived, so any nil
    // silently clobbered the stored name/email (and, via the refresh path, did so
    // on every ~900s token refresh — not just on explicit re-sign-in). These tests
    // pin the merge precedence: live Apple value > server-decoded value > stored value,
    // and assert a non-nil stored value is NEVER replaced with nil.

    /// (a) First sign-in: the live Apple-supplied name/email must win over any
    /// (implausible but possible) server-decoded value — Apple's own authorization
    /// is the freshest source of truth.
    @Test("completeAppleSignIn: live Apple name/email wins over server-decoded value (#78 a)")
    func mergePrefersLiveCredentialOverServerValue() async throws {
        let store = AppleTestTokenStore()  // fresh anon, nothing stored yet
        let service = makeService(store: store)
        _ = await service.accessToken()  // warm cache

        AppleStubURLProtocol.handler = { req in
            (
                .make(status: 200),
                Data(
                    AppleAuthStubs.tokenJSON(
                        access: "account-access", refresh: "account-refresh", anon: "users-id-1",
                        fullName: "Server Name", email: "server@example.com"
                    ).utf8
                )
            )
        }
        defer { AppleStubURLProtocol.handler = nil }

        let result = await service.completeAppleSignIn(
            identityToken: "mock-id-token", authorizationCode: "mock-auth-code",
            rawNonce: "test-raw-nonce", user: "apple-user-1",
            fullName: "Live Name", email: "live@example.com"
        )

        #expect(result?.accountName == "Live Name", "Live Apple credential value must win")
        #expect(result?.accountEmail == "live@example.com", "Live Apple credential value must win")
    }

    /// (b) Fresh install + re-sign-in with an already-consented Apple ID: Apple
    /// supplies nil (only sends it once, ever), but the backend still has the
    /// durable name from the original sign-in — the server-decoded value must
    /// recover it. This is Acceptance criterion #2.
    @Test("completeAppleSignIn: nil live name + server name → name recovered from server (#78 b)")
    func mergeRecoversNameFromServerWhenLiveIsNil() async throws {
        let store = AppleTestTokenStore()  // fresh install: nothing stored locally
        let service = makeService(store: store)
        _ = await service.accessToken()  // warm cache (mints anon)

        AppleStubURLProtocol.handler = { req in
            if req.url?.path == "/api/v1/auth/apple" {
                return (
                    .make(status: 200),
                    Data(
                        AppleAuthStubs.tokenJSON(
                            access: "account-access", refresh: "account-refresh", anon: "users-id-1",
                            fullName: "Recovered Name", email: "recovered@example.com"
                        ).utf8
                    )
                )
            }
            return (.make(status: 500), Data())
        }
        defer { AppleStubURLProtocol.handler = nil }

        let result = await service.completeAppleSignIn(
            identityToken: "mock-id-token", authorizationCode: "mock-auth-code",
            rawNonce: "test-raw-nonce", user: "apple-user-1",
            fullName: nil, email: nil  // Apple sends nothing on a repeat authorization
        )

        #expect(result?.accountName == "Recovered Name", "Server-decoded value must recover the name Apple no longer sends")
        #expect(result?.accountEmail == "recovered@example.com")
    }

    /// (c)+(d) The actual #78 regression: a routine, successful token refresh
    /// (fires every ~900s for any signed-in user per config.access_token_ttl_seconds)
    /// must NEVER clobber the stored account name/email/appleUserId with nil just
    /// because this particular refresh response didn't carry them. Without this fix,
    /// a signed-in user's Settings screen could silently revert to "not signed in"
    /// roughly every 15 minutes of app use.
    @Test("performRefreshOrBootstrap: nil server fields never clobber a stored signed-in account (#78 c/d)")
    func refreshNeverClobbersStoredAccountFieldsWithNil() async throws {
        let seed = AuthTokens(
            accessToken: "old-access", refreshToken: "old-refresh", anonId: "users-id-1",
            accountName: "Stored Name", accountEmail: "stored@example.com", appleUserId: "apple-user-1"
        )
        let store = AppleTestTokenStore(seed: seed)
        let service = makeService(store: store)
        _ = await service.accessToken()  // warm cache with the seeded signed-in tokens

        AppleStubURLProtocol.handler = { req in
            if req.url?.path == "/api/v1/auth/refresh" {
                // Simulate a refresh response with no account fields (nil), as if
                // the backend didn't look them up or the anon_id didn't resolve.
                return (
                    .make(status: 200),
                    Data(AppleAuthStubs.tokenJSON(access: "new-access", refresh: "new-refresh", anon: "users-id-1").utf8)
                )
            }
            return (.make(status: 500), Data())
        }
        defer { AppleStubURLProtocol.handler = nil }

        let refreshed = await service.refreshedAccessToken(replacing: "old-access")

        #expect(refreshed == "new-access", "Refresh must still rotate the access token")
        let stored = store.load()
        #expect(stored?.accountName == "Stored Name", "A nil server field must NEVER clobber a stored non-nil name")
        #expect(stored?.accountEmail == "stored@example.com", "A nil server field must NEVER clobber a stored non-nil email")
        #expect(stored?.appleUserId == "apple-user-1", "appleUserId is never sent by the backend — must always carry forward")
        #expect(stored?.isSignedIn == true, "The signed-in state itself must survive a routine refresh")
    }

    /// Precedence complement to the previous test: when the server DOES decode a
    /// fresh value on refresh (no live source exists during a background refresh),
    /// that server value should still be adopted rather than sticking to a stale
    /// stored one — the merge is "prefer newest available", not "stored always wins".
    @Test("performRefreshOrBootstrap: server-decoded name on refresh overrides a stale stored value (#78 precedence)")
    func refreshAdoptsFreshServerValueOverStaleStored() async throws {
        let seed = AuthTokens(
            accessToken: "old-access", refreshToken: "old-refresh", anonId: "users-id-1",
            accountName: "Stale Name", accountEmail: "stale@example.com", appleUserId: "apple-user-1"
        )
        let store = AppleTestTokenStore(seed: seed)
        let service = makeService(store: store)
        _ = await service.accessToken()

        AppleStubURLProtocol.handler = { req in
            if req.url?.path == "/api/v1/auth/refresh" {
                return (
                    .make(status: 200),
                    Data(
                        AppleAuthStubs.tokenJSON(
                            access: "new-access", refresh: "new-refresh", anon: "users-id-1",
                            fullName: "Updated Name", email: "updated@example.com"
                        ).utf8
                    )
                )
            }
            return (.make(status: 500), Data())
        }
        defer { AppleStubURLProtocol.handler = nil }

        _ = await service.refreshedAccessToken(replacing: "old-access")

        let stored = store.load()
        #expect(stored?.accountName == "Updated Name", "A fresh server value should be adopted, not shadowed by the stale stored one")
        #expect(stored?.accountEmail == "updated@example.com")
        #expect(stored?.appleUserId == "apple-user-1", "appleUserId still carries forward — the backend never sends it")
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
