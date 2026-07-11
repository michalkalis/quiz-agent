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

    /// Return value for `loadOfferings`. Defaults to all three pinned packages.
    var stubbedOfferings: PurchasableOfferings? = PurchasableOfferings(
        monthly: PurchasableProduct(id: StoreProduct.monthlySubId, displayPrice: "$4.99", displayName: "Hangs Unlimited (Monthly)"),
        annual: PurchasableProduct(id: StoreProduct.annualSubId, displayPrice: "$29.99", displayName: "Hangs Unlimited (Annual)"),
        pack: PurchasableProduct(id: StoreProduct.packId, displayPrice: "$1.99", displayName: "+100 Questions")
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

    var loadOfferingsCallCount: Int = 0
    var purchaseCallCount: Int = 0
    var restoreCallCount: Int = 0
    var currentlyEntitledCallCount: Int = 0
    var logInCallCount: Int = 0
    var lastLogInAppUserID: String?

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

    func loadOfferings() async -> PurchasableOfferings? {
        loadOfferingsCallCount += 1
        return stubbedOfferings
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

    func currentlyEntitled(entitlementId: String) async -> Bool {
        currentlyEntitledCallCount += 1
        return stubbedIsEntitled
    }

    func logIn(appUserID: String) async {
        logInCallCount += 1
        lastLogInAppUserID = appUserID
    }
}

// Stable `Mirror` output so snapshot tests (`.dump`) that transitively reflect
// a StoreManager don't pick up the AsyncStream continuation's opaque internals,
// which vary across runs depending on observer registration timing. Variants
// remain distinguishable via StoreManager._offerings and PaywallView.limitError.
extension MockPurchaseService: CustomReflectable {
    nonisolated var customMirror: Mirror {
        Mirror(self, children: [])
    }
}

enum MockPurchaseError: LocalizedError {
    case restoreFailed

    var errorDescription: String? {
        "Mock restore failed"
    }
}
#endif
