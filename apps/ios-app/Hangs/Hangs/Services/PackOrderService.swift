//
//  PackOrderService.swift
//  Hangs
//
//  REST client for quiz-pack-api `/v1/orders` (issue #95 custom packs). Actor-
//  based for thread-safe networking, mirroring `NetworkService`. Targets a
//  DIFFERENT host than NetworkService (`Config.packApiBaseURL`, the pack-api),
//  and authenticates with the founder admin key (Keychain) PLUS the account
//  bearer when one is available, so orders link to the signed-in account.
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
    private let adminKeyStore: AdminKeyStore

    /// In-flight create calls keyed by `idempotencyKey`. A second `createOrder`
    /// for the SAME intent while one is still pending awaits the existing task
    /// instead of firing a second network request — the in-flight guard from
    /// issue #103 finding 6b.
    private var inFlightOrders: [String: Task<OrderCreatedResponse, Error>] = [:]

    init(
        baseURL: String = Config.packApiBaseURL,
        session: URLSession = .shared,
        authService: AuthServiceProtocol?,
        adminKeyStore: AdminKeyStore = AdminKeyStore()
    ) {
        guard let url = URL(string: baseURL) else {
            fatalError("PackOrderService: invalid baseURL '\(baseURL)' — check Config.packApiBaseURL")
        }
        self.baseURL = url
        self.session = session
        self.authService = authService
        self.adminKeyStore = adminKeyStore
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
        var request = await makeRequest(url: url, method: "POST", includeAdminKey: true)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = CreateOrderRequest(
            transactionId: intent.idempotencyKey,
            productId: Self.productId,
            prompt: intent.prompt,
            language: intent.language,
            targetCount: Self.targetCount,
            category: intent.category,
            theme: intent.theme
        )
        request.httpBody = try JSONEncoder().encode(payload)

        Logger.network.debug("🌐 POST \(url, privacy: .public) (create pack order)")
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw PackOrderError.invalidResponse
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
        let request = await makeRequest(url: url, method: "GET", includeAdminKey: false)

        Logger.network.debug("🌐 GET \(url, privacy: .public) (list pack orders)")
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw PackOrderError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw PackOrderError.server(Self.errorMessage(from: data))
        }
        return try JSONDecoder().decode(OrderListResponse.self, from: data).orders
    }

    func getOrder(id: String) async throws -> OrderSnapshot {
        let url = baseURL.appendingPathComponent("/v1/orders/\(id)")
        var request = await makeRequest(url: url, method: "GET", includeAdminKey: true)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        Logger.network.debug("🌐 GET \(url, privacy: .public) (poll pack order)")
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw PackOrderError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw PackOrderError.server(Self.errorMessage(from: data))
        }
        return try JSONDecoder().decode(OrderSnapshot.self, from: data)
    }

    // MARK: - Helpers

    /// Build a request with the admin key (optional) + account bearer (when
    /// available) attached. The admin key is the founder path; the bearer links
    /// the order to the account so it lists under "mine".
    private func makeRequest(url: URL, method: String, includeAdminKey: Bool) async -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if includeAdminKey, let adminKey = adminKeyStore.load() {
            request.setValue(adminKey, forHTTPHeaderField: "X-Admin-Key")
        }
        if let token = await authService?.accessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
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
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return String(localized: "Invalid response from the pack service", comment: "Pack-order error: malformed server response")
        case .server(let message):
            // Server-provided message — already human-readable, do not wrap.
            return message
        }
    }
}
