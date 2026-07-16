//
//  AuthService.swift
//  Hangs
//
//  Server-trusted identity (issue #60 anon + issue #61 Sign in with Apple).
//
//  Owns the device's token pair: an access JWT (short-lived bearer) and an opaque
//  rotating refresh token. Tokens live in the Keychain
//  (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly — readable while the screen
//  is locked during a drive; no biometric gate). On first launch it bootstraps a
//  fresh anonymous identity from the backend; NetworkService asks it for the current
//  access token and, on a 401, for a single-flight refresh.
//
//  Graceful degradation: every public method returns an optional and never
//  throws. When the backend has auth disabled (503 until AUTH_JWT_SECRET is set)
//  or is unreachable, `accessToken()` returns nil and the caller falls back to
//  the legacy `user_id` grace path — the app keeps working through the staged
//  auth rollout.
//
//  Apple credential state is checked on cold launch via `setupAppleCredentialObservation()`.
//  If the stored Apple credential is revoked, the service drops to a fresh anon identity.
//

import AuthenticationServices
import CryptoKit
import Foundation
import os

// MARK: - Token model

/// The token pair persisted in the Keychain.
/// `nonisolated` so the actor (and tests) can read/compare it off the main actor
/// under the project's `-default-isolation=MainActor` build flag.
///
/// Account-specific fields (`accountName`, `accountEmail`, `appleUserId`) are nil
/// for anonymous users and non-nil for users who have signed in with Apple.
/// Optional fields are backwards-compatible: existing Keychain blobs without
/// these keys decode with nil (Codable optional default).
nonisolated struct AuthTokens: Codable, Sendable, Equatable {
    let accessToken: String
    let refreshToken: String
    /// JWT `sub`: the anon identity id (anonymous) OR `users.id` (Apple sign-in).
    let anonId: String

    // MARK: Account fields (nil when anonymous, non-nil after Apple sign-in)

    /// User's full name from Apple (stored on first sign-in only; nil if Apple
    /// didn't supply it or the user is anonymous).
    let accountName: String?
    /// User's email from Apple (may be a private relay address; nil if anonymous).
    let accountEmail: String?
    /// Apple's stable user identifier, used by `ASAuthorizationAppleIDProvider.getCredentialState`
    /// on cold launch to detect revocation. Nil when anonymous.
    let appleUserId: String?

    /// True when the user has a real (non-anonymous) Apple-backed account.
    nonisolated var isSignedIn: Bool { appleUserId != nil }

    /// Backwards-compatible init: anonymous usage (no account fields).
    init(accessToken: String, refreshToken: String, anonId: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.anonId = anonId
        self.accountName = nil
        self.accountEmail = nil
        self.appleUserId = nil
    }

    /// Full init used when an Apple sign-in credential is resolved.
    init(
        accessToken: String,
        refreshToken: String,
        anonId: String,
        accountName: String?,
        accountEmail: String?,
        appleUserId: String?
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.anonId = anonId
        self.accountName = accountName
        self.accountEmail = accountEmail
        self.appleUserId = appleUserId
    }
}

// MARK: - Protocols

/// Minimal token-pair persistence, abstracted so unit tests can swap the
/// Keychain for an in-memory store.
protocol TokenStore: Sendable {
    nonisolated func load() -> AuthTokens?
    nonisolated func save(_ tokens: AuthTokens)
    nonisolated func clear()
}

/// What NetworkService needs from the auth layer. Both methods degrade to `nil`
/// rather than throwing so callers can fall back to the grace path.
protocol AuthServiceProtocol: Sendable {
    /// A valid access token, bootstrapping a fresh identity on first use.
    /// Returns nil when auth is unavailable (backend 503 / offline).
    func accessToken() async -> String?

    /// Force a single-flight refresh, replacing the `staleToken` that just got a
    /// 401. Concurrent callers holding the same stale token share one refresh.
    /// Re-bootstraps if the refresh token is rejected. Returns nil if both fail.
    func refreshedAccessToken(replacing staleToken: String) async -> String?
}

// MARK: - AuthService

actor AuthService: AuthServiceProtocol {
    private let baseURL: URL
    private let session: URLSession
    private let store: TokenStore
    /// App Attest crypto (issue #60 Part B). nil / unsupported (simulator) → the
    /// bootstrap mints a plain identity, which the backend accepts only while
    /// `APP_ATTEST_REQUIRED` is off.
    private let attestor: DeviceAttestor?

    /// In-memory cache of the current pair (mirror of the Keychain).
    private var tokens: AuthTokens?
    /// Single-flight guards so concurrent first-launch requests don't mint two
    /// identities, and concurrent 401s don't fire two refreshes.
    private var bootstrapTask: Task<AuthTokens?, Never>?
    private var refreshTask: Task<AuthTokens?, Never>?
    /// Set once by AppState (issue #93 Session E must-do): called with the new
    /// durable account id right after a successful sign-in, so RC's anon-keyed
    /// purchase history aliases into the signed-in account (RC `logIn`) and the
    /// server-side subscription mirror re-syncs — the designated recovery for a
    /// webhook that landed on the anon id during the purchase↔sign-in window.
    private var onAccountLinked: (@Sendable (String) async -> Void)?
    /// Account id minted before the handler was registered (AppState sets the
    /// handler via a fire-and-forget Task, so an early bootstrap — e.g. via
    /// credential-revocation → dropToFreshAnon — can beat it). Replayed on
    /// registration so the RC alias is never silently skipped (#96 P1).
    private var pendingAccountLink: String?

    /// Registers the account-linked handler. Called once by AppState at launch.
    /// If an identity was already minted before registration, the handler is
    /// replayed with it immediately — closing the mint-before-handler race.
    func setAccountLinkedHandler(_ handler: @escaping @Sendable (String) async -> Void) async {
        onAccountLinked = handler
        if let pending = pendingAccountLink {
            pendingAccountLink = nil
            await handler(pending)
        }
    }

    init(
        baseURL: String = Config.apiBaseURL,
        session: URLSession? = nil,
        store: TokenStore? = nil,
        attestor: DeviceAttestor? = nil
    ) {
        guard let url = URL(string: baseURL) else {
            fatalError("AuthService: invalid baseURL '\(baseURL)' — check Config.apiBaseURL")
        }
        self.baseURL = url

        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: config)
        }

        self.store = store ?? KeychainTokenStore()
        self.attestor = attestor
    }

    // MARK: AuthServiceProtocol

    func accessToken() async -> String? {
        if let tokens {
            return tokens.accessToken
        }
        if let stored = store.load() {
            tokens = stored
            return stored.accessToken
        }
        return await bootstrap()?.accessToken
    }

    func refreshedAccessToken(replacing staleToken: String) async -> String? {
        // Another concurrent request may have already refreshed this token.
        if let current = tokens, current.accessToken != staleToken {
            return current.accessToken
        }
        // Single-flight: dedupe concurrent 401s onto one refresh.
        if let refreshTask {
            return await refreshTask.value?.accessToken
        }
        let task = Task<AuthTokens?, Never> { await self.performRefreshOrBootstrap() }
        refreshTask = task
        let result = await task.value
        refreshTask = nil
        return result?.accessToken
    }

    // MARK: Private

    /// Single-flight bootstrap — concurrent first-launch callers share one mint.
    private func bootstrap() async -> AuthTokens? {
        if let bootstrapTask {
            return await bootstrapTask.value
        }
        let task = Task<AuthTokens?, Never> { await self.performBootstrap() }
        bootstrapTask = task
        let result = await task.value
        bootstrapTask = nil
        return result
    }

    private func performBootstrap() async -> AuthTokens? {
        let minted: AuthTokens?
        if let attestor, attestor.isSupported {
            minted = await performAttestedBootstrap(attestor)
        } else {
            minted = await mintPlain()
        }
        // Every freshly minted durable identity must be re-aliased into
        // RevenueCat (#96 P1): RC is configured once at launch from a keychain
        // snapshot (nil on first launch → RC mints $RCAnonymousID), so a
        // purchase made before this link lands under an id the backend can't
        // map to an account. Apple sign-in has its own call site. A mint that
        // beats handler registration is parked and replayed on registration.
        if let minted {
            if let onAccountLinked {
                await onAccountLinked(minted.anonId)
            } else {
                pendingAccountLink = minted.anonId
            }
        }
        return minted
    }

    /// App Attest path (#60 Part B). Re-bootstrap with the existing key first;
    /// if the backend rejects that assertion (revoked or never-bound key), forget
    /// it and re-attest a fresh one. If App Attest can't produce a credential at
    /// all, degrade to a plain mint — which the backend accepts only while
    /// `APP_ATTEST_REQUIRED` is off, so prod never gets an unattested identity.
    private func performAttestedBootstrap(_ attestor: DeviceAttestor) async -> AuthTokens? {
        if attestor.storedKeyID() != nil {
            if let tokens = await mintAttested(attestor, mode: .assertion) {
                return tokens
            }
            attestor.forgetKey()
        }
        if let tokens = await mintAttested(attestor, mode: .attestation) {
            return tokens
        }
        return await mintPlain()
    }

    /// Fetch a fresh challenge, sign it, and POST the credential to anon-bootstrap.
    /// On a successful *attestation* mint we persist the keyId only now — so a
    /// stored keyId always has a matching backend-bound key.
    private func mintAttested(
        _ attestor: DeviceAttestor, mode: AttestCredential.Mode
    ) async -> AuthTokens? {
        guard let challenge = await fetchChallenge(),
              let cred = await attestor.credential(for: mode, challenge: challenge),
              let body = try? JSONSerialization.data(withJSONObject: cred.bootstrapBody),
              let new = await postTokens(path: "/api/v1/auth/anon-bootstrap", body: body)
        else {
            return nil
        }
        if mode == .attestation {
            attestor.confirmKey(cred.keyID)
        }
        tokens = new
        store.save(new)
        Logger.network.info("🔐 Anon bootstrap (App Attest \(String(describing: mode), privacy: .public)) succeeded")
        return new
    }

    /// Plain (unattested) mint — Part A behaviour and the App Attest fallback.
    private func mintPlain() async -> AuthTokens? {
        guard let new = await postTokens(path: "/api/v1/auth/anon-bootstrap", body: nil) else {
            return nil
        }
        tokens = new
        store.save(new)
        Logger.network.info("🔐 Anon bootstrap succeeded")
        return new
    }

    /// Ask the backend for a one-time App Attest challenge. Returns nil on any
    /// failure so the caller degrades.
    private func fetchChallenge() async -> String? {
        var request = URLRequest(url: baseURL.appendingPathComponent("/api/v1/auth/attest-challenge"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 15
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                return nil
            }
            return try JSONDecoder().decode(ChallengeResponse.self, from: data).challenge
        } catch {
            Logger.network.warning("🔐 attest-challenge error: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Wire shape of the backend `AttestChallengeResponse` (we only need the value).
    private struct ChallengeResponse: Decodable {
        let challenge: String
    }

    private func performRefreshOrBootstrap() async -> AuthTokens? {
        // Hydrate from the Keychain if the in-memory cache is cold (e.g. a 401
        // arrives on the first request after an app restart).
        if tokens == nil {
            tokens = store.load()
        }
        guard let current = tokens else {
            return await performBootstrap()
        }
        let body = try? JSONSerialization.data(withJSONObject: ["refresh_token": current.refreshToken])
        switch await postTokensResult(path: "/api/v1/auth/refresh", body: body) {
        case .success(let new):
            tokens = new
            store.save(new)
            Logger.network.debug("🔐 Refresh rotated token pair")
            return new
        case .rejected:
            // The refresh token was genuinely rejected (revoked / expired / reused).
            if current.isSignedIn {
                // A signed-in (Apple-linked) session was dropped — user-visible.
                // Re-bootstrap anon, then notify UI so it can reload account state (I7).
                Logger.network.error("🔐 Signed-in session dropped (refresh rejected) → re-bootstrapping anon")
                let fresh = await performBootstrap()
                NotificationCenter.default.post(name: .authSignedInSessionDropped, object: nil)
                return fresh
            }
            Logger.network.info("🔐 Refresh rejected → re-bootstrapping")
            return await performBootstrap()
        case .transient:
            // Transient failure (5xx during a deploy, timeout, offline). Keep the
            // stored tokens and surface a retryable nil — never orphan the account
            // by minting a fresh anon over a still-valid refresh token (I1).
            Logger.network.warning("🔐 Refresh transient failure → keeping stored tokens for retry")
            return nil
        }
    }

    /// Outcome of an auth POST that distinguishes a definitive credential rejection
    /// (HTTP 401) from transient failures (5xx, timeout, offline, decode error). The
    /// refresh path relies on this so a transient backend blip during a deploy never
    /// re-bootstraps a fresh anon over a signed-in user's stored tokens (I1).
    private enum AuthPostResult {
        case success(AuthTokens)
        /// The server definitively rejected the credential (HTTP 401).
        case rejected
        /// A transient failure — keep any stored tokens and retry later.
        case transient
    }

    /// POST a request to an auth endpoint, decode the token pair, and classify the
    /// outcome so callers can tell a real 401 from a transient failure.
    private func postTokensResult(path: String, body: Data?) async -> AuthPostResult {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 15

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                Logger.network.warning("🔐 Auth \(path, privacy: .public) → non-HTTP response")
                return .transient
            }
            guard (200...299).contains(http.statusCode) else {
                Logger.network.warning("🔐 Auth \(path, privacy: .public) → HTTP \(http.statusCode, privacy: .public)")
                // Only a 401 is a definitive rejection; everything else is transient.
                return http.statusCode == 401 ? .rejected : .transient
            }
            let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
            return .success(AuthTokens(
                accessToken: decoded.accessToken,
                refreshToken: decoded.refreshToken,
                anonId: decoded.anonId
            ))
        } catch {
            Logger.network.warning("🔐 Auth \(path, privacy: .public) error: \(error.localizedDescription, privacy: .public)")
            return .transient
        }
    }

    /// Optional-returning wrapper for the bootstrap/mint callers, which treat any
    /// non-success outcome as failure. The refresh path uses `postTokensResult`.
    private func postTokens(path: String, body: Data?) async -> AuthTokens? {
        if case .success(let new) = await postTokensResult(path: path, body: body) {
            return new
        }
        return nil
    }

    /// Wire shape of the backend `AuthTokenResponse` (snake_case).
    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String
        let anonId: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case anonId = "anon_id"
        }
    }

    // MARK: - Apple Sign In (issue #61, task 61.6)

    /// Generate a 32-byte random raw nonce, hex-encoded as a 64-character ASCII string.
    ///
    /// The raw nonce string is sent verbatim to the backend as `raw_nonce`. The backend
    /// computes `base64url-nopad(sha256(raw_nonce.encode('utf-8')))` and compares it to
    /// the id_token's `nonce` claim — so the iOS and backend computations must use the
    /// same input (the hex string's UTF-8 bytes), which `hashedNonce(for:)` enforces.
    nonisolated func generateRawNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            // A failed CSPRNG would silently yield an all-zero, predictable nonce —
            // the SIWA replay defence. The call sites (SignInWithAppleButton's
            // synchronous onRequest closure) have no error channel, so abort hard
            // rather than proceed with a forgeable sign-in (#91 item 1).
            fatalError("SecRandomCopyBytes failed (OSStatus \(status)) — cannot generate a secure SIWA nonce")
        }
        return bytes.map { String(format: "%02hhx", $0) }.joined()
    }

    /// Returns `base64url-nopad(SHA256(rawNonce.utf8))`.
    ///
    /// **F6 critical**: this is the exact encoding the backend verifier expects in the
    /// Apple id_token's `nonce` claim. It must be sent as `ASAuthorizationAppleIDRequest.nonce`.
    /// NOT hex (64-char), NOT the raw nonce — only base64url-nopad of the SHA256 digest.
    nonisolated func hashedNonce(for rawNonce: String) -> String {
        let data = Data(rawNonce.utf8)
        let digest = SHA256.hash(data: data)
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Complete an Apple sign-in after `ASAuthorizationAppleIDCredential` is obtained.
    ///
    /// POSTs to `/api/v1/auth/apple` using the **current anon bearer** so the backend
    /// can merge the anon's usage history into the new account (F3). On success, the
    /// stored tokens are swapped from anon to account tokens (sub = users.id).
    ///
    /// - Parameters:
    ///   - identityToken: Apple's id_token string from the credential.
    ///   - authorizationCode: Apple's single-use authorization code from the credential.
    ///   - rawNonce: The raw nonce string generated by `generateRawNonce()`.
    ///   - user: Apple's stable user identifier from the credential.
    ///   - fullName: User's formatted full name (only present on first sign-in).
    ///   - email: User's email (only present on first sign-in; may be private relay).
    /// - Returns: The new account `AuthTokens` on success, nil on failure.
    func completeAppleSignIn(
        identityToken: String,
        authorizationCode: String,
        rawNonce: String,
        user: String,
        fullName: String?,
        email: String?
    ) async -> AuthTokens? {
        // Send the current anon bearer so the backend can merge usage (F3).
        let bearer = tokens?.accessToken ?? store.load()?.accessToken

        var body: [String: Any] = [
            "identity_token": identityToken,
            "authorization_code": authorizationCode,
            "raw_nonce": rawNonce,
        ]
        // `user` object is only populated on first sign-in (Apple sends name/email once).
        var userObject: [String: String] = [:]
        if let fullName { userObject["name"] = fullName }
        if let email { userObject["email"] = email }
        if !userObject.isEmpty { body["user"] = userObject }

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            Logger.network.warning("🔐 Apple sign-in: failed to encode request body")
            return nil
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("/api/v1/auth/apple"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = bodyData
        request.timeoutInterval = 30

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                Logger.network.warning("🔐 Apple sign-in → HTTP \(status, privacy: .public)")
                return nil
            }
            let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
            let newTokens = AuthTokens(
                accessToken: decoded.accessToken,
                refreshToken: decoded.refreshToken,
                anonId: decoded.anonId,     // now users.id, not the anon id
                accountName: fullName,
                accountEmail: email,
                appleUserId: user
            )
            tokens = newTokens
            store.save(newTokens)
            // Verify the Keychain actually persisted the account linkage. A silent
            // save failure would lose the account on the next launch (re-bootstrapping
            // anon), so surface it as a sign-in failure rather than reporting success (I3).
            guard store.load()?.appleUserId == user else {
                Logger.network.error("🔐 Apple sign-in: token persistence failed — reporting sign-in failure")
                return nil
            }
            Logger.network.info("🔐 Apple sign-in succeeded: sub=\(decoded.anonId, privacy: .public)")
            if let onAccountLinked {
                await onAccountLinked(decoded.anonId)
            }
            return newTokens
        } catch {
            Logger.network.warning("🔐 Apple sign-in error: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Check the stored Apple credential state on cold launch.
    ///
    /// If the credential is revoked, not found, or transferred to another device,
    /// the service drops to a fresh anonymous identity. Should be called once at
    /// startup after `setupAppleCredentialObservation()`.
    func checkAppleCredentialState() async {
        let stored = tokens ?? store.load()
        guard let appleUserId = stored?.appleUserId else {
            return  // anonymous user — nothing to check
        }
        let state = await withCheckedContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: appleUserId) { state, _ in
                continuation.resume(returning: state)
            }
        }
        switch state {
        case .authorized:
            break  // credential is still valid
        case .revoked, .notFound, .transferred:
            Logger.network.info("🔐 Apple credential \(String(describing: state), privacy: .public) → dropping to anon")
            await dropToFreshAnon()
        @unknown default:
            break
        }
    }

    /// Register for `ASAuthorizationAppleIDProvider.credentialRevokedNotification` and check
    /// the current credential state. Call once from `AppState` after the service is created.
    func setupAppleCredentialObservation() async {
        // 1. Check state right now (cold-launch revocation guard).
        await checkAppleCredentialState()

        // 2. Observe future revocations. The notification fires on an unspecified queue;
        //    the Task re-enters the actor safely.
        NotificationCenter.default.addObserver(
            forName: ASAuthorizationAppleIDProvider.credentialRevokedNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.dropToFreshAnon() }
        }
    }

    /// Sign out: revoke the refresh-token family on the backend (best-effort), then
    /// clear stored account tokens and re-bootstrap a fresh anonymous identity.
    func signOut() async {
        Logger.network.info("🔐 Sign out → dropping to anon")
        // Best-effort backend logout to revoke the refresh-token family (I2).
        // Fire-and-forget: failures are ignored so sign-out always completes.
        if let refreshToken = (tokens ?? store.load())?.refreshToken {
            await postLogout(refreshToken: refreshToken)
        }
        await dropToFreshAnon()
    }

    /// Best-effort POST /auth/logout to revoke the refresh-token family server-side.
    /// The endpoint always returns 204; the result and any error are ignored (I2).
    private func postLogout(refreshToken: String) async {
        guard let body = try? JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken]) else {
            return
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("/api/v1/auth/logout"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 15
        _ = try? await session.data(for: request)
    }

    /// Delete the account on the backend (DELETE /auth/me), then clear tokens locally and
    /// re-bootstrap a fresh anonymous identity.
    ///
    /// A 2xx from the backend means the account is gone. Local data is cleared regardless
    /// of the backend revoke step (backend handles Apple revoke best-effort per F4).
    /// Throws `AuthError.notSignedIn` if there are no tokens, or `AuthError.serverError`
    /// for non-2xx responses.
    func deleteAccount() async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("/api/v1/auth/me"))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 30

        let (_, response) = try await sendAuthorized(request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            Logger.network.warning("🔐 DELETE /auth/me → HTTP \(status, privacy: .public)")
            throw AuthError.serverError(status)
        }

        // Account deleted on backend — clear locally and start a fresh anon identity.
        await dropToFreshAnon()
        Logger.network.info("🔐 Account deleted; re-bootstrapped anon")
    }

    /// Fetch the account's data export (GET /auth/me/export, GDPR Art. 20).
    /// Returns the raw JSON response body. Throws on non-2xx or network failure.
    func exportData() async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent("/api/v1/auth/me/export"))
        request.httpMethod = "GET"
        request.timeoutInterval = 30

        let (data, response) = try await sendAuthorized(request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            Logger.network.warning("🔐 GET /auth/me/export → HTTP \(status, privacy: .public)")
            throw AuthError.serverError(status)
        }
        return data
    }

    /// Send an authorized account-management request, refreshing the access token
    /// once on a 401 (mirrors `NetworkService.sendAuthorized`) so a routine token
    /// expiry is retried transparently instead of surfacing a 401 to the user (I4).
    /// Throws `AuthError.notSignedIn` when no access token is available at all.
    private func sendAuthorized(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard let token = await accessToken() else {
            throw AuthError.notSignedIn
        }
        var req = request
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 401 else {
            return (data, response)
        }
        guard let fresh = await refreshedAccessToken(replacing: token) else {
            return (data, response)  // refresh unavailable → surface the 401
        }
        req.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
        return try await session.data(for: req)
    }

    /// Drop the stored tokens (anon or account), clear the in-memory cache, and
    /// re-bootstrap a fresh anonymous identity.
    private func dropToFreshAnon() async {
        tokens = nil
        store.clear()
        _ = await performBootstrap()
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted when a signed-in (Apple-linked) session is definitively dropped — the
    /// backend rejected the refresh token with a 401 and the service fell back to a
    /// fresh anonymous identity. UI observes this to reload the account section (I1/I7).
    nonisolated static let authSignedInSessionDropped = Notification.Name("authSignedInSessionDropped")
}

// MARK: - AuthError

enum AuthError: LocalizedError, Sendable {
    case notSignedIn
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return String(localized: "Not signed in", comment: "Auth error: no active session")
        case .serverError(let code):
            return String(localized: "Server error (\(code))", comment: "Auth error: server returned non-2xx; placeholder is the HTTP status code")
        }
    }
}

// MARK: - KeychainTokenStore

/// Stores the token pair as a single JSON blob in the Keychain under one
/// generic-password item. Accessible after first unlock, this-device-only — so
/// it survives a locked screen during a drive but never leaves the device.
nonisolated struct KeychainTokenStore: TokenStore {
    private let service = "\(Bundle.main.bundleIdentifier ?? "com.missinghue.hangs").auth"
    private let account = "anon_tokens"

    func load() -> AuthTokens? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                Logger.network.warning("🔐 Keychain load failed: OSStatus \(status, privacy: .public)")
            }
            return nil
        }
        return try? JSONDecoder().decode(AuthTokens.self, from: data)
    }

    func save(_ tokens: AuthTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }

        // Upsert: try update first, fall back to add.
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                Logger.network.warning("🔐 Keychain add failed: OSStatus \(addStatus, privacy: .public)")
            }
        } else if updateStatus != errSecSuccess {
            Logger.network.warning("🔐 Keychain update failed: OSStatus \(updateStatus, privacy: .public)")
        }
    }

    func clear() {
        let status = SecItemDelete(baseQuery as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Logger.network.warning("🔐 Keychain delete failed: OSStatus \(status, privacy: .public)")
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
