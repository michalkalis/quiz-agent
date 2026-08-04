//
//  PackOrderService.swift
//  Hangs
//
//  REST client for quiz-pack-api `/v1/orders` (issue #95 custom packs). Actor-
//  based for thread-safe networking, mirroring `NetworkService`. Targets a
//  DIFFERENT host than NetworkService (`Config.packApiBaseURL`, the pack-api),
//  and always attaches the account bearer so orders link to the account.
//
//  Order authorisation (#140): the user path sends the StoreKit JWS
//  (`X-StoreKit-JWS`) from the intent's `paymentProof`. The founder admin-key
//  path (`X-Admin-Key`, Keychain) is compiled OUT of Release builds — it
//  exists for internal Debug testing only.
//

@preconcurrency import Foundation
import os

/// Protocol for custom-pack order operations.
protocol PackOrderServiceProtocol: Sendable {
    /// `POST /v1/orders` — create (or idempotently replay) an order for the
    /// given intent. Calling this twice with the SAME `intent` (same
    /// `idempotencyKey`) sends the same `transaction_id` both times, so a
    /// client-side retry replays the original order instead of minting a new
    /// paid one (issue #103 finding 6).
    func createOrder(intent: PackOrderIntent) async throws -> OrderCreatedResponse
    /// `GET /v1/orders` — the caller's orders, newest-first. Bearer required.
    func listOrders() async throws -> [OrderSnapshot]
    /// `GET /v1/orders/{id}` — single order snapshot (poll target).
    func getOrder(id: String) async throws -> OrderSnapshot
}

/// Thread-safe pack-order service using a Swift 6 actor.
actor PackOrderService: PackOrderServiceProtocol {
    /// v1 single tier — server overwrites `target_count` from the tier anyway.
    private nonisolated static let productId = "pack_30"
    private nonisolated static let targetCount = 30

    private let baseURL: URL
    private let session: URLSession
    private let authService: AuthServiceProtocol?
    /// Reads the stored admin key (Debug internal door). A closure — not the
    /// concrete Keychain store — so unit tests can pin header behaviour without
    /// racing other suites for the simulator's shared, persistent Keychain.
    private let adminKey: @Sendable () -> String?

    /// In-flight create calls keyed by `idempotencyKey`. A second `createOrder`
    /// for the SAME intent while one is still pending awaits the existing task
    /// instead of firing a second network request — the in-flight guard from
    /// issue #103 finding 6b.
    private var inFlightOrders: [String: Task<OrderCreatedResponse, Error>] = [:]

    init(
        baseURL: String = Config.packApiBaseURL,
        session: URLSession = .shared,
        authService: AuthServiceProtocol?,
        adminKey: @escaping @Sendable () -> String? = { AdminKeyStore().load() }
    ) {
        guard let url = URL(string: baseURL) else {
            fatalError("PackOrderService: invalid baseURL '\(baseURL)' — check Config.packApiBaseURL")
        }
        self.baseURL = url
        self.session = session
        self.authService = authService
        self.adminKey = adminKey
    }

    // MARK: - Requests

    func createOrder(intent: PackOrderIntent) async throws -> OrderCreatedResponse {
        // In-flight guard: a second submit of the SAME intent while the first
        // is still pending is a no-op that awaits the original task's result
        // rather than sending a duplicate request.
        if let pending = inFlightOrders[intent.idempotencyKey] {
            return try await pending.value
        }

        let task = Task { try await self.performCreateOrder(intent: intent) }
        inFlightOrders[intent.idempotencyKey] = task
        defer { inFlightOrders[intent.idempotencyKey] = nil }
        return try await task.value
    }

    private func performCreateOrder(intent: PackOrderIntent) async throws -> OrderCreatedResponse {
        let url = baseURL.appendingPathComponent("/v1/orders")
        // User path: the StoreKit JWS authorises the order and the admin key is
        // never attached. Debug admin path (no proof): admin key only.
        var request = makeRequest(url: url, method: "POST", includeAdminKey: intent.paymentProof == nil)
        if let proof = intent.paymentProof {
            request.setValue(proof.jws, forHTTPHeaderField: "X-StoreKit-JWS")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = CreateOrderRequest(
            transactionId: intent.idempotencyKey,
            productId: intent.paymentProof?.productId ?? Self.productId,
            prompt: intent.prompt,
            language: intent.language,
            targetCount: Self.targetCount,
            category: intent.category,
            theme: intent.theme
        )
        request.httpBody = try JSONEncoder().encode(payload)

        Logger.network.debug("🌐 POST \(url, privacy: .public) (create pack order)")
        let (data, response) = try await send(request)

        guard let http = response as? HTTPURLResponse else {
            throw PackOrderError.invalidResponse
        }
        guard http.statusCode != 401 else {
            throw PackOrderError.unauthorized
        }
        // 202 create / 200 idempotent replay both carry the created payload.
        guard http.statusCode == 200 || http.statusCode == 202 else {
            throw PackOrderError.server(Self.errorMessage(from: data))
        }
        return try JSONDecoder().decode(OrderCreatedResponse.self, from: data)
    }

    func listOrders() async throws -> [OrderSnapshot] {
        let url = baseURL.appendingPathComponent("/v1/orders")
        // List is owner-scoped: bearer required, no admin-key alternative.
        let request = makeRequest(url: url, method: "GET", includeAdminKey: false)

        Logger.network.debug("🌐 GET \(url, privacy: .public) (list pack orders)")
        let (data, response) = try await send(request)

        guard let http = response as? HTTPURLResponse else {
            throw PackOrderError.invalidResponse
        }
        guard http.statusCode != 401 else {
            throw PackOrderError.unauthorized
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw PackOrderError.server(Self.errorMessage(from: data))
        }
        return try JSONDecoder().decode(OrderListResponse.self, from: data).orders
    }

    func getOrder(id: String) async throws -> OrderSnapshot {
        let url = baseURL.appendingPathComponent("/v1/orders/\(id)")
        var request = makeRequest(url: url, method: "GET", includeAdminKey: true)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        Logger.network.debug("🌐 GET \(url, privacy: .public) (poll pack order)")
        let (data, response) = try await send(request)

        guard let http = response as? HTTPURLResponse else {
            throw PackOrderError.invalidResponse
        }
        guard http.statusCode != 401 else {
            throw PackOrderError.unauthorized
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw PackOrderError.server(Self.errorMessage(from: data))
        }
        return try JSONDecoder().decode(OrderSnapshot.self, from: data)
    }

    // MARK: - Helpers

    /// Build a request with the admin key (optional) attached. The admin key is the
    /// internal Debug-only door (#140) — the attachment is compiled out of Release,
    /// so a user build can never send `X-Admin-Key` no matter what the Keychain
    /// holds. The account bearer — which links the order to the account so it lists
    /// under "mine" — is attached by `send`, because a 401 has to re-attach a
    /// refreshed one.
    private func makeRequest(url: URL, method: String, includeAdminKey: Bool) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        #if DEBUG
            if includeAdminKey, let key = adminKey() {
                request.setValue(key, forHTTPHeaderField: "X-Admin-Key")
            }
        #endif
        return request
    }

    /// Send through the shared 401-refresh-retry convention
    /// (`AuthServiceProtocol.sendAuthorized`): it attaches the bearer and, on a 401,
    /// refreshes the access token once and retries the request once.
    ///
    /// This matters most on the 1 Hz `getOrder` poll `OrderPackViewModel` runs for
    /// the whole generation — the access token routinely expires mid-poll, and
    /// before this every such 401 ate the poller's tolerated-failure budget and
    /// dead-ended a PAID order on an opaque `.server` message (#133 V16). With no
    /// `authService` (founder admin-key path, and this service's own unit tests) the
    /// request goes out unchanged.
    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard let authService else {
            return try await session.data(for: request)
        }
        return try await authService.sendAuthorized(request, on: session)
    }

    /// Decode the backend error body defensively. Hand-raised errors are
    /// `{"detail": "<string>"}`; Pydantic validation errors are
    /// `{"detail": [ … ]}` (array) — the string decode fails on the array form
    /// and falls back to a generic message rather than crashing.
    private nonisolated static func errorMessage(from data: Data) -> String {
        if let decoded = try? JSONDecoder().decode(DetailStringError.self, from: data) {
            return decoded.detail
        }
        return String(localized: "The pack service returned an error. Please try again.", comment: "Fallback message when the pack-order API returns a non-2xx response we can't parse")
    }
}

// MARK: - Error decoding

/// Hand-raised backend error shape: `{"detail": "<string>"}`. Decoding fails
/// (harmlessly) on the Pydantic array form, which triggers the generic fallback.
private nonisolated struct DetailStringError: Decodable, Sendable {
    let detail: String
}

enum PackOrderError: LocalizedError {
    case invalidResponse
    /// A 401 that survived the refresh-and-retry in `send` — the session is
    /// genuinely gone, not merely expired. Distinct from `.server` so a paid pack
    /// flow tells the user to sign in again instead of showing the API's opaque
    /// "returned an error" fallback (#133 V16).
    case unauthorized
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return String(localized: "Invalid response from the pack service", comment: "Pack-order error: malformed server response")
        case .unauthorized:
            return String(localized: "Your session expired. Please sign in again to continue.", comment: "Pack-order error: the request was still unauthorized after a token refresh")
        case let .server(message):
            // Server-provided message — already human-readable, do not wrap.
            return message
        }
    }
}
