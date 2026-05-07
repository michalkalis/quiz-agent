//
//  StoreManagerTests.swift
//  HangsTests
//
//  Daemon-free unit tests for StoreManager using MockPurchaseService.
//
//  Context — why this was rewritten (2026-05-07):
//
//  The previous version used SKTestSession and had 9 tests, 6 of which silently
//  skipped on iOS 26 simulator via a `guard await storeKitAvailable() else { return }`
//  guard — making CI falsely green on revenue-critical code.
//
//  Root cause: `SKInternalErrorDomain Code=3` on iOS 26 sim is a confirmed
//  Apple-side regression (Flutter #184678; Apple Developer Forum thread/808030,
//  storekittest tag, May 2026). The StoreKit XPC daemon is unreachable from the
//  unit-test host process on iOS 26 sim. Adding the
//  `com.apple.developer.in-app-payments` entitlement does NOT fix this —
//  that entitlement is for production-device distribution signing, not simulator
//  unit tests. TSAN-off likewise does not help.
//
//  Solution: StoreManager now accepts a `PurchaseService` protocol. All daemon-
//  dependent work lives in `LivePurchaseService`. `MockPurchaseService` provides
//  deterministic, daemon-free control over every code path in StoreManager.
//  Manual TestFlight verification covers "we are actually talking to StoreKit."
//

import Foundation
import Testing
import ConcurrencyExtras
@testable import Hangs

// MARK: - Helpers

private extension PurchasableProduct {
    static let sample = PurchasableProduct(
        id: StoreProduct.unlimited,
        displayPrice: "$4.99",
        displayName: "Hangs Unlimited"
    )
}

/// Makes a fresh (mock, manager) pair and drains the two init Tasks
/// (loadProduct + checkPurchaseStatus) so state is stable before assertions.
@MainActor
private func makeManager(
    product: PurchasableProduct? = .sample,
    isEntitled: Bool = false,
    purchaseOutcome: PurchaseOutcome = .success,
    purchaseError: Error? = nil,
    restoreShouldFail: Bool = false
) async -> (StoreManager, MockPurchaseService) {
    let mock = MockPurchaseService()
    mock.stubbedProduct = product
    mock.stubbedIsEntitled = isEntitled
    mock.stubbedPurchaseOutcome = purchaseOutcome
    mock.stubbedPurchaseError = purchaseError
    mock.stubbedRestoreShouldFail = restoreShouldFail

    let manager = StoreManager(purchaseService: mock)
    // Drain the unstructured Tasks spawned in init().
    // Two yields settle loadProduct() and checkPurchaseStatus() on the main actor.
    await Task.yield()
    await Task.yield()
    return (manager, mock)
}

// MARK: - StoreManagerTests

@Suite("StoreManager Tests")
@MainActor
struct StoreManagerTests {

    // MARK: 1. loadProduct — sets product when service returns a PurchasableProduct

    @Test("loadProduct sets product when service returns a product")
    func loadProductSetsProduct() async {
        let (manager, _) = await makeManager(product: .sample)
        // Call explicitly to also verify the direct path
        await manager.loadProduct()
        #expect(manager.product == .sample)
    }

    // MARK: 2. loadProduct failure path — service returns nil, product stays nil

    @Test("loadProduct with nil result leaves product nil")
    func loadProductNilLeavesProductNil() async {
        let (manager, _) = await makeManager(product: nil)
        await manager.loadProduct()
        #expect(manager.product == nil)
    }

    // MARK: 3. purchase() .success — isPurchased=true, no error, isLoading=false

    @Test("purchase success sets isPurchased true")
    func purchaseSuccessSetsIsPurchased() async {
        let (manager, _) = await makeManager(product: .sample, purchaseOutcome: .success)
        // product is set from init drain; call purchase
        await manager.purchase()

        #expect(manager.isPurchased == true)
        #expect(manager.purchaseError == nil)
        #expect(manager.isLoading == false)
    }

    // MARK: 4. purchase() .userCancelled — isPurchased unchanged, no error

    @Test("purchase userCancelled leaves isPurchased false")
    func purchaseCancelledLeavesIsPurchasedFalse() async {
        let (manager, _) = await makeManager(product: .sample, purchaseOutcome: .userCancelled)
        await manager.purchase()

        #expect(manager.isPurchased == false)
        #expect(manager.purchaseError == nil)
        #expect(manager.isLoading == false)
    }

    // MARK: 5. purchase() .pending — isPurchased unchanged, no error

    @Test("purchase pending leaves isPurchased false")
    func purchasePendingLeavesIsPurchasedFalse() async {
        let (manager, _) = await makeManager(product: .sample, purchaseOutcome: .pending)
        await manager.purchase()

        #expect(manager.isPurchased == false)
        #expect(manager.purchaseError == nil)
        #expect(manager.isLoading == false)
    }

    // MARK: 6. purchase() thrown error — sets purchaseError, isPurchased false

    @Test("purchase error sets purchaseError")
    func purchaseErrorSetsPurchaseError() async {
        let (manager, _) = await makeManager(
            product: .sample,
            purchaseError: StoreError.failedVerification
        )
        await manager.purchase()

        #expect(manager.purchaseError != nil)
        #expect(manager.isPurchased == false)
        #expect(manager.isLoading == false)
    }

    // MARK: 7. purchase() with product == nil — sets error, no service call

    @Test("purchase with nil product sets error without calling service")
    func purchaseWithNilProductSetsError() async {
        let (manager, mock) = await makeManager(product: nil)
        // product is nil because service returned nil in init drain
        await manager.purchase()

        #expect(manager.purchaseError == "Product not available")
        // loadProductCallCount was called once in init; purchaseCallCount must be 0
        #expect(mock.purchaseCallCount == 0)
        #expect(manager.isPurchased == false)
    }

    // MARK: 8. restorePurchases() happy path — flips isPurchased=true when entitled

    @Test("restorePurchases flips isPurchased when entitled after restore")
    func restorePurchasesHappyPath() async {
        let (manager, mock) = await makeManager(isEntitled: true)

        await manager.restorePurchases()

        #expect(mock.restoreCallCount == 1)
        #expect(manager.isPurchased == true)
        #expect(manager.purchaseError == nil)
        #expect(manager.isLoading == false)
    }

    // MARK: 9. restorePurchases() failure path — sets purchaseError, isLoading=false

    @Test("restorePurchases failure sets purchaseError")
    func restorePurchasesFailureSetsError() async {
        let (manager, _) = await makeManager(restoreShouldFail: true)

        await manager.restorePurchases()

        #expect(manager.purchaseError != nil)
        #expect(manager.isLoading == false)
    }

    // MARK: 10. checkPurchaseStatus — reflects currentlyEntitled from service

    @Test("checkPurchaseStatus reflects service entitlement state (true)")
    func checkPurchaseStatusTrueWhenEntitled() async {
        let (manager, _) = await makeManager(isEntitled: true)
        // Call explicitly to verify the direct path
        await manager.checkPurchaseStatus()
        #expect(manager.isPurchased == true)
    }

    @Test("checkPurchaseStatus returns false when not entitled")
    func checkPurchaseStatusFalseWhenNotEntitled() async {
        let (manager, _) = await makeManager(isEntitled: false)
        await manager.checkPurchaseStatus()
        #expect(manager.isPurchased == false)
    }

    // MARK: 11. Transaction listener flips isPurchased on entitlement update

    @Test("transaction listener flips isPurchased on verified EntitlementUpdate")
    func transactionListenerFlipsIsPurchased() async {
        // withMainSerialExecutor collapses all Task scheduling onto one executor so
        // a single Task.yield() is sufficient to let the listener process the event.
        // Per audit A2-5: no confirmation here, so executor can be the outermost scope.
        await withMainSerialExecutor {
            let mock = MockPurchaseService()
            mock.stubbedIsEntitled = false
            let manager = StoreManager(purchaseService: mock)
            // Drain init tasks
            await Task.yield()
            await Task.yield()

            #expect(manager.isPurchased == false)

            // Emit a synthetic verified entitlement update
            mock.emitEntitlementUpdate(
                EntitlementUpdate(productID: StoreProduct.unlimited, isVerified: true)
            )

            // One yield is sufficient under withMainSerialExecutor
            await Task.yield()

            #expect(manager.isPurchased == true)
        }
    }
}
