//
//  MockPurchaseService.swift
//  Hangs
//
//  Mock PurchaseService for DEBUG builds (SwiftUI previews, unit tests, UI-test mode).
//  Configurable via closure properties — set before the call to override behaviour.
//

#if DEBUG
import Foundation

@MainActor
final class MockPurchaseService: PurchaseService {

    // MARK: - Configuration

    /// Return value for `loadProduct`. Defaults to a sample product.
    var stubbedProduct: PurchasableProduct? = PurchasableProduct(
        id: StoreProduct.unlimited,
        displayPrice: "$4.99",
        displayName: "Hangs Unlimited"
    )

    /// Return value for `purchase`. Defaults to `.success`.
    var stubbedPurchaseOutcome: PurchaseOutcome = .success

    /// If non-nil, `purchase` throws this error instead of returning an outcome.
    var stubbedPurchaseError: Error? = nil

    /// If `true`, `restore()` throws a generic error.
    var stubbedRestoreShouldFail: Bool = false

    /// Return value for `currentlyEntitled`. Defaults to `false`.
    var stubbedIsEntitled: Bool = false

    // MARK: - Call Tracking

    var loadProductCallCount: Int = 0
    var purchaseCallCount: Int = 0
    var restoreCallCount: Int = 0
    var currentlyEntitledCallCount: Int = 0

    // MARK: - Entitlement Stream

    private let continuation: AsyncStream<EntitlementUpdate>.Continuation
    let entitlementUpdates: AsyncStream<EntitlementUpdate>

    init() {
        var cont: AsyncStream<EntitlementUpdate>.Continuation!
        self.entitlementUpdates = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    /// Emit a synthetic entitlement update to the transaction listener.
    func emitEntitlementUpdate(_ update: EntitlementUpdate) {
        continuation.yield(update)
    }

    // MARK: - PurchaseService

    func loadProduct(id: String) async -> PurchasableProduct? {
        loadProductCallCount += 1
        return stubbedProduct
    }

    func purchase(productID: String) async throws -> PurchaseOutcome {
        purchaseCallCount += 1
        if let error = stubbedPurchaseError {
            throw error
        }
        return stubbedPurchaseOutcome
    }

    func restore() async throws {
        restoreCallCount += 1
        if stubbedRestoreShouldFail {
            throw MockPurchaseError.restoreFailed
        }
    }

    func currentlyEntitled(productID: String) async -> Bool {
        currentlyEntitledCallCount += 1
        return stubbedIsEntitled
    }
}

enum MockPurchaseError: LocalizedError {
    case restoreFailed

    var errorDescription: String? {
        "Mock restore failed"
    }
}
#endif
