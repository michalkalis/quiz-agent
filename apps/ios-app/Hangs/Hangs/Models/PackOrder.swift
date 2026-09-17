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
/// billing — a duplicate.
///
/// With a `paymentProof` (issue #140, the user path) the idempotency key IS the
/// StoreKit transaction id — the server cross-checks it against the JWS. With
/// no proof (Debug admin path) it stays a synthetic `"admin-<uuid>"`.
nonisolated struct PackOrderIntent: Equatable, Sendable {
    let idempotencyKey: String
    let prompt: String
    let language: String
    let category: String?
    let theme: String?
    /// StoreKit proof authorising this order; nil = Debug admin path.
    let paymentProof: PackPaymentProof?

    init(
        prompt: String,
        language: String,
        category: String?,
        theme: String?,
        paymentProof: PackPaymentProof? = nil,
        idempotencyKey: String = "admin-\(UUID().uuidString)"
    ) {
        self.idempotencyKey = paymentProof?.transactionId ?? idempotencyKey
        self.prompt = prompt
        self.language = language
        self.category = category
        self.theme = theme
        self.paymentProof = paymentProof
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
    /// Set as soon as the FIRST batch of questions is persisted (#182) — so it
    /// can be non-null while `status` is still `in_progress`. This is what you
    /// pass to play the pack.
    let packId: String?
    /// Decimal-as-string (e.g. `"1.234560"`) or null — NOT a number.
    let llmCostUsd: String?
    let searchCostCents: Int
    let job: JobSnapshot?
    /// How many questions are ready so far (#103 F5, live-growing since #182).
    /// Nil until the pack row exists.
    let actualCount: Int?
    /// #182: `generating` while the worker is still adding questions to an
    /// already-playable pack, `complete`/`failed` once it stops, nil when there
    /// is no pack yet. Kept raw — an unknown future value must never crash a row.
    let packGenerationStatus: String?

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
        case actualCount = "actual_count"
        case packGenerationStatus = "pack_generation_status"
    }

    /// The order finished successfully and `packId` is populated.
    var isDelivered: Bool { status == "delivered" }

    /// #182: the pack can be played NOW. Since the generator persists questions
    /// in batches, a pack becomes playable at the first batch — while the order
    /// is still `in_progress` and the rest keeps generating behind the player.
    /// A failed/refunded order is never playable from the app even if a partial
    /// pack exists: that row keeps today's "Try again".
    var isPlayable: Bool { packId != nil && !isFailure }

    /// Questions ready to play right now (`actual_count`, 0 before the first
    /// batch lands) — the numerator of the "5 of 30 ready" copy.
    var readyCount: Int { actualCount ?? 0 }

    /// The pack is playable AND the worker is still adding to it, so the ready
    /// count will keep growing while the player plays.
    var isStillGenerating: Bool {
        isPlayable && (packGenerationStatus == "generating" || !isTerminal)
    }

    /// The poll loop should stop: delivered, failed, or refunded.
    var isTerminal: Bool {
        status == "delivered" || status == "failed" || status == "refunded"
    }

    /// A terminal state that is NOT a success (drives the `.failed` UI).
    var isFailure: Bool {
        status == "failed" || status == "refunded"
    }

    /// The one failure the user can act on: `failed` is what
    /// `POST /v1/orders/{id}/retry` accepts (it 409s anything else), so it is
    /// also the only row that may offer "Try again" (#146). `refunded` is money
    /// already returned — nothing left to re-run.
    var isRetryable: Bool { status == "failed" }

    /// Localized user-facing label for the wire status (issue #137) — the raw
    /// wire value must never be rendered. An unknown future status falls back
    /// to the raw value rather than hiding or crashing the row.
    var statusLabel: String {
        switch status {
        case "pending":
            String(localized: "Pending", comment: "Custom-pack order status: queued, generation not started yet")
        case "in_progress":
            String(localized: "In progress", comment: "Custom-pack order status: the pack is being generated")
        case "delivered":
            String(localized: "Delivered", comment: "Custom-pack order status: pack generated and playable")
        case "failed":
            String(localized: "Failed", comment: "Custom-pack order status: generation failed")
        case "refunded":
            String(localized: "Refunded", comment: "Custom-pack order status: the order was refunded")
        default:
            status
        }
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
