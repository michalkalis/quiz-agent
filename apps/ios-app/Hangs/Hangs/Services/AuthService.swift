//
//  AuthService.swift
//  Hangs
//
//  Server-trusted anonymous identity (issue #60, tasks 60.7/60.8).
//
//  Owns the device's anonymous token pair: an access JWT (short-lived bearer)
//  and an opaque rotating refresh token. Tokens live in the Keychain
//  (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly — readable while the screen
//  is locked during a drive; no biometric gate). On first launch it bootstraps a
//  fresh identity from the backend; NetworkService asks it for the current access
//  token and, on a 401, for a single-flight refresh.
//
//  Graceful degradation: every public method returns an optional and never
//  throws. When the backend has auth disabled (503 until AUTH_JWT_SECRET is set)
//  or is unreachable, `accessToken()` returns nil and the caller falls back to
//  the legacy `user_id` grace path — the app keeps working through the staged
//  auth rollout.
//

import Foundation
import os

// MARK: - Token model

/// The anonymous token pair persisted in the Keychain.
/// `nonisolated` so the actor (and tests) can read/compare it off the main actor
/// under the project's `-default-isolation=MainActor` build flag.
nonisolated struct AuthTokens: Codable, Sendable, Equatable {
    let accessToken: String
    let refreshToken: String
    /// Server-assigned anonymous subject id (the JWT `sub`). Stored for
    /// diagnostics / future account-upgrade flows.
    let anonId: String
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
        if let attestor, attestor.isSupported {
            return await performAttestedBootstrap(attestor)
        }
        return await mintPlain()
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
        guard let refreshToken = tokens?.refreshToken else {
            return await performBootstrap()
        }
        let body = try? JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
        if let new = await postTokens(path: "/api/v1/auth/refresh", body: body) {
            tokens = new
            store.save(new)
            Logger.network.debug("🔐 Refresh rotated token pair")
            return new
        }
        // Refresh rejected (revoked/expired/reused) or unreachable → start a
        // fresh identity. If the backend is merely offline, the re-bootstrap
        // fails too (nil), so no orphan identity is minted.
        Logger.network.info("🔐 Refresh failed → re-bootstrapping")
        return await performBootstrap()
    }

    /// POST a request to an auth endpoint and decode the token pair. Returns nil
    /// on any non-2xx status or transport/decoding error (caller degrades).
    private func postTokens(path: String, body: Data?) async -> AuthTokens? {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 15

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                Logger.network.warning("🔐 Auth \(path, privacy: .public) → HTTP \(status, privacy: .public)")
                return nil
            }
            let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
            return AuthTokens(
                accessToken: decoded.accessToken,
                refreshToken: decoded.refreshToken,
                anonId: decoded.anonId
            )
        } catch {
            Logger.network.warning("🔐 Auth \(path, privacy: .public) error: \(error.localizedDescription, privacy: .public)")
            return nil
        }
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
