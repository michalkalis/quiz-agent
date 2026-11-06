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
    private let prices: [PackSize: String]
    private let state: OSAllocatedUnfairLock<State>

    private struct State {
        var pending: PackPaymentProof?
        var purchasedSizes: [PackSize] = []
    }

    /// - Parameter prices: what StoreKit "returns"; a size left out is a
    ///   product the App Store doesn't sell (yet).
    init(
        purchaseResult: Result<PackPaymentProof, PackPurchaseError> = .success(MockPackPurchaseService.mockProof),
        pending: PackPaymentProof? = nil,
        prices: [PackSize: String] = [:]
    ) {
        self.purchaseResult = purchaseResult
        self.prices = prices
        self.state = OSAllocatedUnfairLock(initialState: State(pending: pending))
    }

    /// How many times `purchase(_:)` ran — lets a test prove a retry reused
    /// the pending proof instead of charging again.
    var purchaseCallCount: Int {
        state.withLock { $0.purchasedSizes.count }
    }

    /// The size each payment sheet was opened for, in order.
    var purchasedSizes: [PackSize] {
        state.withLock { $0.purchasedSizes }
    }

    /// Like StoreKit, the proof names the product that was bought.
    func purchase(_ size: PackSize) async throws -> PackPaymentProof {
        state.withLock { $0.purchasedSizes.append(size) }
        let canned = try purchaseResult.get()
        let proof = PackPaymentProof(transactionId: canned.transactionId, productId: size.productId, jws: canned.jws)
        state.withLock { $0.pending = proof }
        return proof
    }

    func pendingProof() -> PackPaymentProof? {
        state.withLock { $0.pending }
    }

    func clearPendingProof() {
        state.withLock { $0.pending = nil }
    }

    func displayPrices() async -> [PackSize: String] {
        prices
    }
}
