//
//  PackOrderCodableTests.swift
//  HangsTests
//
//  #95 contract-match guard. The iOS Codable structs must decode exactly what
//  quiz-pack-api sends: snake_case keys, UUID/datetime as strings, Decimal money
//  as a STRING (not a number), nullable fields as nil, and — critically — an
//  UNKNOWN status string must decode without throwing so the poll loop survives
//  a server enum the client hasn't seen yet.
//

@testable import Hangs
import Foundation
import Testing

@Suite("PackOrder Codable contract")
struct PackOrderCodableTests {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test("a fully delivered order decodes field-by-field, cost as a String")
    func decodesDelivered() throws {
        let json = """
        {
          "order_id": "11111111-1111-1111-1111-111111111111",
          "status": "delivered",
          "product_id": "pack_30",
          "target_count": 30,
          "language": "en",
          "category": "history",
          "theme": "ancient rome",
          "created_at": "2026-07-13T10:00:00Z",
          "delivered_at": "2026-07-13T10:05:00Z",
          "pack_id": "22222222-2222-2222-2222-222222222222",
          "llm_cost_usd": "1.23",
          "search_cost_cents": 4,
          "job": {
            "job_id": "33333333-3333-3333-3333-333333333333",
            "status": "done",
            "progress": 100,
            "retry_count": 0,
            "total_cost_cents": 24,
            "error": null,
            "updated_at": "2026-07-13T10:05:00Z"
          }
        }
        """
        let order = try decode(OrderSnapshot.self, json)
        #expect(order.id == "11111111-1111-1111-1111-111111111111")
        #expect(order.status == "delivered")
        #expect(order.isDelivered)
        #expect(order.isTerminal)
        #expect(order.productId == "pack_30")
        #expect(order.targetCount == 30)
        #expect(order.language == "en")
        #expect(order.category == "history")
        #expect(order.theme == "ancient rome")
        #expect(order.deliveredAt == "2026-07-13T10:05:00Z")
        #expect(order.packId == "22222222-2222-2222-2222-222222222222")
        // Decimal-as-string: decoded verbatim, NOT as a Double.
        #expect(order.llmCostUsd == "1.23")
        #expect(order.searchCostCents == 4)
        #expect(order.job?.status == "done")
        #expect(order.job?.progress == 100)
    }

    @Test("a pending order decodes nulls as nil (pack_id, cost, job)")
    func decodesPending() throws {
        let json = """
        {
          "order_id": "44444444-4444-4444-4444-444444444444",
          "status": "pending",
          "product_id": "pack_30",
          "target_count": 30,
          "language": "sk",
          "category": null,
          "theme": null,
          "created_at": "2026-07-13T09:50:00Z",
          "delivered_at": null,
          "pack_id": null,
          "llm_cost_usd": null,
          "search_cost_cents": 0,
          "job": null
        }
        """
        let order = try decode(OrderSnapshot.self, json)
        #expect(order.status == "pending")
        #expect(!order.isDelivered)
        #expect(!order.isTerminal)
        #expect(order.category == nil)
        #expect(order.theme == nil)
        #expect(order.deliveredAt == nil)
        #expect(order.packId == nil)
        #expect(order.llmCostUsd == nil)
        #expect(order.job == nil)
    }

    @Test("the list response is an OBJECT wrapping the array, newest-first order preserved")
    func decodesList() throws {
        let json = """
        {
          "orders": [
            {
              "order_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
              "status": "delivered",
              "product_id": "pack_30",
              "target_count": 30,
              "language": "en",
              "category": null,
              "theme": null,
              "created_at": "2026-07-13T10:00:00Z",
              "delivered_at": "2026-07-13T10:05:00Z",
              "pack_id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
              "llm_cost_usd": "0.50",
              "search_cost_cents": 1,
              "job": null
            },
            {
              "order_id": "cccccccc-cccc-cccc-cccc-cccccccccccc",
              "status": "pending",
              "product_id": "pack_30",
              "target_count": 30,
              "language": "en",
              "category": null,
              "theme": null,
              "created_at": "2026-07-13T09:00:00Z",
              "delivered_at": null,
              "pack_id": null,
              "llm_cost_usd": null,
              "search_cost_cents": 0,
              "job": null
            }
          ]
        }
        """
        let list = try decode(OrderListResponse.self, json)
        #expect(list.orders.count == 2)
        #expect(list.orders.first?.id == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        #expect(list.orders.last?.status == "pending")
    }

    @Test("an unknown status string decodes without throwing — poll loop must survive")
    func decodesUnknownStatus() throws {
        let json = """
        {
          "order_id": "55555555-5555-5555-5555-555555555555",
          "status": "quantum_superposition",
          "product_id": "pack_30",
          "target_count": 30,
          "language": "en",
          "category": null,
          "theme": null,
          "created_at": "2026-07-13T09:00:00Z",
          "delivered_at": null,
          "pack_id": null,
          "llm_cost_usd": null,
          "search_cost_cents": 0,
          "job": null
        }
        """
        let order = try decode(OrderSnapshot.self, json)
        // Unknown status: not delivered, not terminal → keep polling, never crash.
        #expect(order.status == "quantum_superposition")
        #expect(!order.isDelivered)
        #expect(!order.isTerminal)
        #expect(!order.isFailure)
    }

    @Test("create response decodes its three fields")
    func decodesCreateResponse() throws {
        let json = """
        {
          "order_id": "66666666-6666-6666-6666-666666666666",
          "status": "pending",
          "created_at": "2026-07-13T09:00:00Z"
        }
        """
        let created = try decode(OrderCreatedResponse.self, json)
        #expect(created.orderId == "66666666-6666-6666-6666-666666666666")
        #expect(created.status == "pending")
        #expect(created.createdAt == "2026-07-13T09:00:00Z")
    }

    @Test("an empty list decodes to zero orders — the common fresh-account state")
    func decodesEmptyList() throws {
        // A brand-new account has ordered nothing; MyPacksView must render an
        // empty state, not crash. `{"orders": []}` is the exact wire shape.
        let list = try decode(OrderListResponse.self, #"{ "orders": [] }"#)
        #expect(list.orders.isEmpty)
    }

    @Test("request uses snake_case keys and OMITS category/theme when nil (absence = no filter)")
    func encodeOmitsNilFilters() throws {
        // The server treats an ABSENT category/theme as "no filter"; encoding an
        // explicit null could be interpreted differently. `encodeIfPresent` must
        // drop them entirely when nil — this test fails if that regresses to
        // `encode` (explicit null keys).
        let bare = CreateOrderRequest(
            transactionId: "admin-abc", productId: "pack_30",
            prompt: "ten chars!", language: "en", targetCount: 30,
            category: nil, theme: nil
        )
        let bareObj = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(bare)
        ) as? [String: Any] ?? [:]
        let keys = Set(bareObj.keys)
        #expect(keys.contains("transaction_id"))
        #expect(keys.contains("product_id"))
        #expect(keys.contains("target_count"))
        #expect(!keys.contains("category"))
        #expect(!keys.contains("theme"))

        // When set, they ARE present under the snake_case wire keys.
        let filtered = CreateOrderRequest(
            transactionId: "admin-abc", productId: "pack_30",
            prompt: "ten chars!", language: "en", targetCount: 30,
            category: "history", theme: "rome"
        )
        let filteredObj = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(filtered)
        ) as? [String: Any] ?? [:]
        #expect((filteredObj["category"] as? String) == "history")
        #expect((filteredObj["theme"] as? String) == "rome")
    }
}
