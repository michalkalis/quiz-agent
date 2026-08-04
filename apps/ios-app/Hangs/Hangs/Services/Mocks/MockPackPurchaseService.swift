//
//  MockPackPurchaseService.swift
//  Hangs
//
//  Canned PackPurchaseServiceProtocol for previews + unit tests (issue #140).
//  Like MockPackOrderService, deliberately NOT #if DEBUG-gated: it is injected
//  by AppState's UI-test/preview wiring, which compiles in every configuration.
//
//  The pending slot is in-memory (lock-guarded), so tests exercise the
//  purchase-once / reuse-pending behaviour without touching UserDefaults.
//

import Foundation
import os

final class MockPackPurchaseService: PackPurchaseServiceProtocol, Sendable {
    static let mockProof = PackPaymentProof(
        transactionId: "990000000000001",
        productId: "pack_30",
        jws: "mock.jws.payload"
    )

    private let purchaseResult: Result<PackPaymentProof, PackPurchaseError>
    private let state: OSAllocatedUnfairLock<State>

    private struct State {
        var pending: PackPaymentProof?
        var purchaseCallCount = 0
    }

    init(
        purchaseResult: Result<PackPaymentProof, PackPurchaseError> = .success(MockPackPurchaseService.mockProof),
        pending: PackPaymentProof? = nil
    ) {
        self.purchaseResult = purchaseResult
        self.state = OSAllocatedUnfairLock(initialState: State(pending: pending))
    }

    /// How many times `purchase()` ran — lets a test prove a retry reused the
    /// pending proof instead of charging again.
    var purchaseCallCount: Int {
        state.withLock { $0.purchaseCallCount }
    }

    func purchase() async throws -> PackPaymentProof {
        state.withLock { $0.purchaseCallCount += 1 }
        let proof = try purchaseResult.get()
        state.withLock { $0.pending = proof }
        return proof
    }

    func pendingProof() -> PackPaymentProof? {
        state.withLock { $0.pending }
    }

    func clearPendingProof() {
        state.withLock { $0.pending = nil }
    }
}
