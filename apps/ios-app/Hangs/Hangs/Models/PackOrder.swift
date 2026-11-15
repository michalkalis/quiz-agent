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
import SwiftUI

// MARK: - Difficulty

/// The level a buyer picks for a custom pack (#224, 224.3). `mixed` is the
/// fourth, equally explicit choice: no fixed level, the generator's own
/// easy/medium/hard spread. It sends no `difficulty`, which is exactly what the
/// backend treats as a mixed batch (NULL), so no backend change is needed.
nonisolated enum PackDifficulty: String, CaseIterable, Identifiable, Sendable {
    case easy
    case medium
    case hard
    case mixed

    var id: String { rawValue }

    /// Value for `CreateOrderRequest.difficulty` (`easy|medium|hard`); nil for
    /// `mixed`, which is sent as an absent field.
    var wireValue: String? {
        self == .mixed ? nil : rawValue
    }

    /// Label key for `Text`, so it follows the view's locale like every other
    /// string on the order screens.
    var label: LocalizedStringKey {
        switch self {
        case .easy: "Easy"
        case .medium: "Medium"
        case .hard: "Hard"
        case .mixed: "Mixed"
        }
    }
}

// MARK: - Audience (#236)

/// Who a custom pack is written for (#236, 236.1). A content setting on the
/// order ("questions for 7 to 9"), never a fact about the player: it is not
/// stored on the account and never sent to analytics as a player property.
/// Adults is the default, so unlike difficulty it never blocks the order.
nonisolated enum PackAudience: String, CaseIterable, Identifiable, Sendable {
    case adults
    case kids4to6 = "kids_4_6"
    case kids7to9 = "kids_7_9"
    case kids10to12 = "kids_10_12"

    var id: String { rawValue }

    var isChild: Bool { self != .adults }

    /// Value for the `audience` request field; nil for adults, which the
    /// server reads exactly like a build before the choice, so an adult order
    /// stays byte-for-byte today's request.
    var wireValue: String? {
        isChild ? rawValue : nil
    }

    var label: LocalizedStringKey {
        switch self {
        case .adults: "Adults"
        case .kids4to6: "Kids 4–6"
        case .kids7to9: "Kids 7–9"
        case .kids10to12: "Kids 10–12"
        }
    }
}

// MARK: - Topic check (#233)

/// Verdict of `POST /v1/orders/topic-check`, asked before the player pays.
/// `softened`: the questions will be toned down; `blocked`: pick another topic.
nonisolated enum TopicVerdict: String, Sendable {
    case ok, softened, blocked
}

nonisolated struct TopicCheckRequest: Encodable, Sendable {
    let prompt: String
    let language: String
    /// #236: a child band checks the topic at the stricter child tier.
    var audience: PackAudience = .adults

    enum CodingKeys: String, CodingKey {
        case prompt, language, audience
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(language, forKey: .language)
        try container.encodeIfPresent(audience.wireValue, forKey: .audience)
    }
}

/// `verdict` is a plain string on the wire; an unknown value reads as `.ok`.
nonisolated struct TopicCheckResponse: Decodable, Sendable {
    let verdict: String
}

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
    /// Optional on the wire (older servers/clients omit it); the order form
    /// always sends one.
    var difficulty: PackDifficulty? = nil
    /// #236: sent only for a child band (`PackAudience.wireValue`).
    var audience: PackAudience = .adults

    enum CodingKeys: String, CodingKey {
        case transactionId = "transaction_id"
        case productId = "product_id"
        case prompt
        case language
        case targetCount = "target_count"
        case category
        case theme
        case difficulty
        case audience
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
        try container.encodeIfPresent(difficulty?.wireValue, forKey: .difficulty)
        try container.encodeIfPresent(audience.wireValue, forKey: .audience)
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
    /// Buyer-chosen level (#224); nil only for callers that predate the picker.
    let difficulty: PackDifficulty?
    /// #236: who the pack is written for.
    let audience: PackAudience
    /// StoreKit proof authorising this order; nil = Debug admin path.
    let paymentProof: PackPaymentProof?
    /// #228.6: the pack size ordered. With a proof it is the size that proof
    /// paid for, whatever was asked: the server sizes the pack from the
    /// receipt's product, so the intent can never disagree with it.
    let size: PackSize

    init(
        prompt: String,
        language: String,
        category: String?,
        theme: String?,
        difficulty: PackDifficulty? = nil,
        audience: PackAudience = .adults,
        size: PackSize = .standard,
        paymentProof: PackPaymentProof? = nil,
        idempotencyKey: String = "admin-\(UUID().uuidString)"
    ) {
        self.idempotencyKey = paymentProof?.transactionId ?? idempotencyKey
        self.size = paymentProof.flatMap { PackSize(productId: $0.productId) } ?? size
        self.prompt = prompt
        self.language = language
        self.category = category
        self.theme = theme
        self.difficulty = difficulty
        self.audience = audience
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
    /// The topic the buyer typed. Optional because servers before it was
    /// added don't send it; a `var` with a default so the mocks' memberwise
    /// inits stay as they are.
    var prompt: String? = nil
    /// #236: `kids_4_6` / `kids_7_9` / `kids_10_12`, `adults`, or null (an
    /// order from a build before the choice: an adult pack). Kept raw like
    /// `status`, so an unknown future band never breaks a row.
    var audience: String? = nil

    var id: String { orderId }

    /// The buyer's topic, trimmed; nil when absent or blank.
    var topic: String? {
        guard let trimmed = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// What a pack card is titled by: the buyer's topic, so packs can be told
    /// apart (TestFlight 2026-10-10: every card read "EN"); the previous
    /// category / language-code title when an older server sends no prompt.
    var displayTitle: String {
        topic ?? category ?? language.uppercased()
    }

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
        case prompt
        case audience
    }

    /// #198.4: the pack's colour key — its pack id once one exists, the order
    /// id before that, so every order row has a colour of its own.
    var colorKey: String { packId ?? orderId }

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

    /// #232: every question is made, so the pack can be sent to a friend or
    /// played together (the server refuses a pack still being made).
    var isFinishedPack: Bool { isPlayable && !isStillGenerating }

    /// #200: the questions the pack holds once generation is over: what was
    /// persisted (`actual_count`), the ordered count when the server did not
    /// say. Nil while it still grows, so it can never count as played through.
    var playableQuestionCount: Int? {
        isStillGenerating ? nil : (actualCount ?? targetCount)
    }

    /// #200: what a play control hands the quiz start; nil without a pack.
    var packPlay: PackPlay? {
        packId.map { PackPlay(packId: $0, questionCount: playableQuestionCount) }
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
        // Queued and generating read the same to the player (#188 G14): one
        // word on Home and in the pack list.
        case "pending", "in_progress":
            String(localized: "Preparing", bundle: .interface, locale: .interface, comment: "Custom-pack order status: queued or being generated, not playable yet")
        case "delivered":
            String(localized: "Delivered", bundle: .interface, locale: .interface, comment: "Custom-pack order status: pack generated and playable")
        case "failed":
            String(localized: "Failed", bundle: .interface, locale: .interface, comment: "Custom-pack order status: generation failed")
        case "refunded":
            String(localized: "Refunded", bundle: .interface, locale: .interface, comment: "Custom-pack order status: the order was refunded")
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
