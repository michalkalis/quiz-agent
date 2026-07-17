//
//  PackOrder.swift
//  Hangs
//
//  Custom quiz-pack ordering models (issue #95). Wire contract = quiz-pack-api
//  `/v1/orders`. Field names are snake_case exactly (no automatic conversion) —
//  mirror `Session.swift` with explicit CodingKeys. Decimal money values arrive
//  as JSON strings and are decoded as `String?`, never numbers.
//

@preconcurrency import Foundation

// MARK: - Create order request

/// Body of `POST /v1/orders`. `category`/`theme` are omitted from the JSON when
/// nil (server treats absence as "no filter").
nonisolated struct CreateOrderRequest: Encodable, Sendable {
    let transactionId: String
    let productId: String
    let prompt: String
    let language: String
    let targetCount: Int
    let category: String?
    let theme: String?

    enum CodingKeys: String, CodingKey {
        case transactionId = "transaction_id"
        case productId = "product_id"
        case prompt
        case language
        case targetCount = "target_count"
        case category
        case theme
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(transactionId, forKey: .transactionId)
        try container.encode(productId, forKey: .productId)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(language, forKey: .language)
        try container.encode(targetCount, forKey: .targetCount)
        try container.encodeIfPresent(category, forKey: .category)
        try container.encodeIfPresent(theme, forKey: .theme)
    }
}

// MARK: - Create order intent

/// The draft order parameters PLUS a STABLE idempotency key, minted ONCE when
/// the intent is formed (issue #103 finding 6). Reusing the SAME intent across
/// a retry (client timeout, resubmit after a failed attempt) sends the same
/// `transaction_id` both times, so the server's dedup (quiz-pack-api
/// `orders.py`) replays the original order instead of creating — and
/// billing — a duplicate. `idempotencyKey` is admin-path only today
/// (defaults to `"admin-<uuid>"`); once packs carry a real StoreKit
/// transaction, that id slots into `idempotencyKey` unchanged — no signature
/// change needed.
nonisolated struct PackOrderIntent: Equatable, Sendable {
    let idempotencyKey: String
    let prompt: String
    let language: String
    let category: String?
    let theme: String?

    init(
        prompt: String,
        language: String,
        category: String?,
        theme: String?,
        idempotencyKey: String = "admin-\(UUID().uuidString)"
    ) {
        self.idempotencyKey = idempotencyKey
        self.prompt = prompt
        self.language = language
        self.category = category
        self.theme = theme
    }
}

// MARK: - Create order response

/// `202` (created) / `200` (idempotent replay) response of `POST /v1/orders`.
nonisolated struct OrderCreatedResponse: Decodable, Sendable {
    let orderId: String
    let status: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case orderId = "order_id"
        case status
        case createdAt = "created_at"
    }
}

// MARK: - Order snapshot

/// A single order as returned by `GET /v1/orders/{id}` and inside the list
/// response. `status` is kept as a raw `String` and interpreted through
/// computed helpers so an unrecognised server status never crashes the poll
/// loop (defensive decode — issue #95 contract note).
nonisolated struct OrderSnapshot: Decodable, Identifiable, Sendable, Equatable {
    let orderId: String
    /// Raw wire status: `pending|in_progress|delivered|failed|refunded` (or an
    /// as-yet-unknown future value — never assumed exhaustive).
    let status: String
    let productId: String
    let targetCount: Int
    let language: String
    let category: String?
    let theme: String?
    let createdAt: String
    let deliveredAt: String?
    /// Null until the order is `delivered`; this is what you pass to play the pack.
    let packId: String?
    /// Decimal-as-string (e.g. `"1.234560"`) or null — NOT a number.
    let llmCostUsd: String?
    let searchCostCents: Int
    let job: JobSnapshot?

    var id: String { orderId }

    enum CodingKeys: String, CodingKey {
        case orderId = "order_id"
        case status
        case productId = "product_id"
        case targetCount = "target_count"
        case language
        case category
        case theme
        case createdAt = "created_at"
        case deliveredAt = "delivered_at"
        case packId = "pack_id"
        case llmCostUsd = "llm_cost_usd"
        case searchCostCents = "search_cost_cents"
        case job
    }

    /// The order finished successfully and `packId` is populated.
    var isDelivered: Bool { status == "delivered" }

    /// The poll loop should stop: delivered, failed, or refunded.
    var isTerminal: Bool {
        status == "delivered" || status == "failed" || status == "refunded"
    }

    /// A terminal state that is NOT a success (drives the `.failed` UI).
    var isFailure: Bool {
        status == "failed" || status == "refunded"
    }
}

// MARK: - Order list response

/// `GET /v1/orders` returns an OBJECT wrapping the array, not a bare array.
nonisolated struct OrderListResponse: Decodable, Sendable {
    let orders: [OrderSnapshot]
}

// MARK: - Job snapshot

/// Generation-job progress attached to an order. `status` uses a DIFFERENT set
/// of values than the order status (`queued|sourcing|generating|critiquing|
/// verifying|scoring|persisting|done|failed`); kept raw for the same defensive
/// reason.
nonisolated struct JobSnapshot: Decodable, Sendable, Equatable {
    let jobId: String
    let status: String
    let progress: Int
    let retryCount: Int
    let totalCostCents: Int
    let error: String?
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case status
        case progress
        case retryCount = "retry_count"
        case totalCostCents = "total_cost_cents"
        case error
        case updatedAt = "updated_at"
    }
}
