//
//  MockPackOrderService.swift
//  Hangs
//
//  Canned PackOrderServiceProtocol for previews + unit tests (issue #95).
//  Deliberately NOT #if DEBUG-gated: it is the default injected into AppState's
//  test/preview init, which is compiled in every configuration.
//
//  Configured entirely at construction (immutable config) so it stays Sendable.
//  By default poll behaviour is a single terminal snapshot — `getOrder` returns
//  it immediately, so tests reach `.delivered`/`.failed` without waiting on the
//  real 1 Hz cadence. Pass `getSequence` to instead hand back a different
//  snapshot per `getOrder` call (e.g. pending → delivered), which lets a test
//  drive the VM through the intermediate `.polling` state and prove the loop
//  actually iterates rather than short-circuiting on call #1. Pass `getResults`
//  for a per-call sequence that can also THROW (e.g. a transient error then a
//  delivered snapshot), so a test can prove the poll retries past a blip. The
//  per-call cursor is guarded by a lock (no `nonisolated(unsafe)`).
//

import Foundation
import os

final class MockPackOrderService: PackOrderServiceProtocol, Sendable {
    private let createResult: Result<OrderCreatedResponse, PackFailure>
    private let getResult: Result<OrderSnapshot, PackFailure>
    private let listResult: Result<[OrderSnapshot], PackFailure>
    /// When non-empty, `getOrder` returns `getSequence[callIndex]`, clamping to
    /// the last element once exhausted. Empty → fall back to `getResult`.
    private let getSequence: [OrderSnapshot]
    /// When non-empty, `getOrder` returns/throws `getResults[callIndex]` (clamping
    /// to the last element) — a per-call sequence that can inject a transient error
    /// then a success. Takes precedence over `getSequence`/`getResult`.
    private let getResults: [Result<OrderSnapshot, PackFailure>]
    private let getCallIndex = OSAllocatedUnfairLock(initialState: 0)

    /// Boxed error so the whole config stays value-typed / Sendable.
    struct PackFailure: Error, Sendable {
        let message: String
        init(_ message: String = "mock pack failure") { self.message = message }
    }

    init(
        createResult: Result<OrderCreatedResponse, PackFailure> = .success(.mockCreated),
        getResult: Result<OrderSnapshot, PackFailure> = .success(.mockDelivered),
        listResult: Result<[OrderSnapshot], PackFailure> = .success([.mockDelivered, .mockPending]),
        getSequence: [OrderSnapshot] = [],
        getResults: [Result<OrderSnapshot, PackFailure>] = []
    ) {
        self.createResult = createResult
        self.getResult = getResult
        self.listResult = listResult
        self.getSequence = getSequence
        self.getResults = getResults
    }

    func createOrder(prompt: String, language: String, category: String?, theme: String?) async throws -> OrderCreatedResponse {
        try createResult.get()
    }

    func listOrders() async throws -> [OrderSnapshot] {
        try listResult.get()
    }

    func getOrder(id: String) async throws -> OrderSnapshot {
        // Per-call Result sequence (throw-then-succeed etc.) wins so a test can
        // inject a transient error mid-poll; clamps to the last element.
        if !getResults.isEmpty {
            return try getCallIndex.withLock { index in
                let result = getResults[min(index, getResults.count - 1)]
                index += 1
                return try result.get()
            }
        }
        guard !getSequence.isEmpty else { return try getResult.get() }
        return getCallIndex.withLock { index in
            let snapshot = getSequence[min(index, getSequence.count - 1)]
            index += 1
            return snapshot
        }
    }
}

// MARK: - Canned fixtures

extension OrderCreatedResponse {
    static let mockCreated = OrderCreatedResponse(
        orderId: "11111111-1111-1111-1111-111111111111",
        status: "pending",
        createdAt: "2026-07-13T10:00:00Z"
    )
}

extension OrderSnapshot {
    static let mockDelivered = OrderSnapshot(
        orderId: "11111111-1111-1111-1111-111111111111",
        status: "delivered",
        productId: "pack_30",
        targetCount: 30,
        language: "en",
        category: "history",
        theme: nil,
        createdAt: "2026-07-13T10:00:00Z",
        deliveredAt: "2026-07-13T10:05:00Z",
        packId: "22222222-2222-2222-2222-222222222222",
        llmCostUsd: "0.210000",
        searchCostCents: 3,
        job: JobSnapshot(
            jobId: "33333333-3333-3333-3333-333333333333",
            status: "done",
            progress: 100,
            retryCount: 0,
            totalCostCents: 24,
            error: nil,
            updatedAt: "2026-07-13T10:05:00Z"
        )
    )

    static let mockPending = OrderSnapshot(
        orderId: "44444444-4444-4444-4444-444444444444",
        status: "in_progress",
        productId: "pack_30",
        targetCount: 30,
        language: "en",
        category: nil,
        theme: nil,
        createdAt: "2026-07-13T09:50:00Z",
        deliveredAt: nil,
        packId: nil,
        llmCostUsd: nil,
        searchCostCents: 0,
        job: JobSnapshot(
            jobId: "55555555-5555-5555-5555-555555555555",
            status: "generating",
            progress: 40,
            retryCount: 0,
            totalCostCents: 10,
            error: nil,
            updatedAt: "2026-07-13T09:55:00Z"
        )
    )

    static let mockFailed = OrderSnapshot(
        orderId: "66666666-6666-6666-6666-666666666666",
        status: "failed",
        productId: "pack_30",
        targetCount: 30,
        language: "en",
        category: nil,
        theme: nil,
        createdAt: "2026-07-13T09:00:00Z",
        deliveredAt: nil,
        packId: nil,
        llmCostUsd: nil,
        searchCostCents: 0,
        job: JobSnapshot(
            jobId: "77777777-7777-7777-7777-777777777777",
            status: "failed",
            progress: 60,
            retryCount: 2,
            totalCostCents: 12,
            error: "generation failed",
            updatedAt: "2026-07-13T09:10:00Z"
        )
    )
}
