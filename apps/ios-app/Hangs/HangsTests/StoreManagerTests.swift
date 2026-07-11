//
//  StoreManagerTests.swift
//  HangsTests
//
//  Daemon-free unit tests for StoreManager using MockPurchaseService.
//
//  Context — why this was rewritten (2026-05-07, updated 2026-07-11 for #93):
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
//  Manual TestFlight verification covers "we are actually talking to StoreKit/RC."
//
//  #93: StoreManager swapped from a single StoreKit product to RevenueCat
//  Offerings (monthly/annual sub + consumable pack). Tests updated accordingly.
//

import Foundation
import Testing
import ConcurrencyExtras
@testable import Hangs

// MARK: - Helpers

private extension PurchasableOfferings {
    static let sample = PurchasableOfferings(
        monthly: PurchasableProduct(id: StoreProduct.monthlySubId, displayPrice: "$4.99", displayName: "Hangs Unlimited (Monthly)"),
        annual: PurchasableProduct(id: StoreProduct.annualSubId, displayPrice: "$29.99", displayName: "Hangs Unlimited (Annual)"),
        pack: PurchasableProduct(id: StoreProduct.packId, displayPrice: "$1.99", displayName: "+100 Questions")
    )
}

/// Makes a fresh (mock, manager) pair and drains the two init Tasks
/// (loadOfferings + checkPurchaseStatus) so state is stable before assertions.
@MainActor
private func makeManager(
    offerings: PurchasableOfferings? = .sample,
    isEntitled: Bool = false,
    purchaseOutcome: PurchaseOutcome = .success,
    purchaseError: Error? = nil,
    restoreShouldFail: Bool = false
) async -> (StoreManager, MockPurchaseService) {
    let mock = MockPurchaseService()
    mock.stubbedOfferings = offerings
    mock.stubbedIsEntitled = isEntitled
    mock.stubbedPurchaseOutcome = purchaseOutcome
    mock.stubbedPurchaseError = purchaseError
    mock.stubbedRestoreShouldFail = restoreShouldFail

    let manager = StoreManager(purchaseService: mock)
    // Drain the unstructured Tasks spawned in init().
    // Two yields settle loadOfferings() and checkPurchaseStatus() on the main actor.
    await Task.yield()
    await Task.yield()
    return (manager, mock)
}

// MARK: - StoreManagerTests

@Suite("StoreManager Tests")
@MainActor
struct StoreManagerTests {

    // MARK: 1. loadOfferings — sets offerings when service returns them

    @Test("loadOfferings sets offerings when service returns a PurchasableOfferings")
    func loadOfferingsSetsOfferings() async {
        let (manager, _) = await makeManager(offerings: .sample)
        // Call explicitly to also verify the direct path
        await manager.loadOfferings()
        #expect(manager.offerings == .sample)
    }

    // MARK: 2. loadOfferings failure path — service returns nil, offerings stays nil

    @Test("loadOfferings with nil result leaves offerings nil")
    func loadOfferingsNilLeavesOfferingsNil() async {
        let (manager, _) = await makeManager(offerings: nil)
        await manager.loadOfferings()
        #expect(manager.offerings == nil)
    }

    // MARK: 3. purchase(monthly) .success — isPurchased=true, no error, isLoading=false

    @Test("purchase monthly success sets isPurchased true")
    func purchaseMonthlySuccessSetsIsPurchased() async {
        let (manager, _) = await makeManager(offerings: .sample, isEntitled: true, purchaseOutcome: .success)
        await manager.purchase(productID: StoreProduct.monthlySubId)

        #expect(manager.isPurchased == true)
        #expect(manager.purchaseError == nil)
        #expect(manager.isLoading == false)
    }

    // MARK: 4. purchase(pack) .success — does NOT set isPurchased (consumable, not a sub)

    @Test("purchase pack success does not set isPurchased")
    func purchasePackSuccessDoesNotSetIsPurchased() async {
        let (manager, _) = await makeManager(offerings: .sample, isEntitled: false, purchaseOutcome: .success)
        await manager.purchase(productID: StoreProduct.packId)

        #expect(manager.isPurchased == false)
        #expect(manager.purchaseError == nil)
    }

    // MARK: 5. purchase() .userCancelled — isPurchased unchanged, no error

    @Test("purchase userCancelled leaves isPurchased false")
    func purchaseCancelledLeavesIsPurchasedFalse() async {
        let (manager, _) = await makeManager(offerings: .sample, purchaseOutcome: .userCancelled)
        await manager.purchase(productID: StoreProduct.monthlySubId)

        #expect(manager.isPurchased == false)
        #expect(manager.purchaseError == nil)
        #expect(manager.isLoading == false)
    }

    // MARK: 6. purchase() .pending — isPurchased unchanged, no error

    @Test("purchase pending leaves isPurchased false")
    func purchasePendingLeavesIsPurchasedFalse() async {
        let (manager, _) = await makeManager(offerings: .sample, purchaseOutcome: .pending)
        await manager.purchase(productID: StoreProduct.monthlySubId)

        #expect(manager.isPurchased == false)
        #expect(manager.purchaseError == nil)
        #expect(manager.isLoading == false)
    }

    // MARK: 7. purchase() thrown error — sets purchaseError, isPurchased false

    @Test("purchase error sets purchaseError")
    func purchaseErrorSetsPurchaseError() async {
        let (manager, _) = await makeManager(
            offerings: .sample,
            purchaseError: StoreError.failedVerification
        )
        await manager.purchase(productID: StoreProduct.monthlySubId)

        #expect(manager.purchaseError != nil)
        #expect(manager.isPurchased == false)
        #expect(manager.isLoading == false)
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

    // MARK: 11. Entitlement listener flips isPurchased on active update

    @Test("entitlement listener flips isPurchased on active EntitlementUpdate")
    func entitlementListenerFlipsIsPurchased() async {
        // withMainSerialExecutor collapses all Task scheduling onto one executor so
        // a single Task.yield() is sufficient to let the listener process the event.
        await withMainSerialExecutor {
            let mock = MockPurchaseService()
            mock.stubbedIsEntitled = false
            let manager = StoreManager(purchaseService: mock)
            // Drain init tasks
            await Task.yield()
            await Task.yield()

            #expect(manager.isPurchased == false)

            // Emit a synthetic active entitlement update
            mock.emitEntitlementUpdate(
                EntitlementUpdate(entitlementId: StoreProduct.entitlementId, isActive: true)
            )

            // One yield is sufficient under withMainSerialExecutor
            await Task.yield()

            #expect(manager.isPurchased == true)
        }
    }

    // MARK: 12. logIn — aliases RC identity and re-checks entitlement (#93 Session E)

    @Test("logIn aliases the RC identity and re-checks entitlement")
    func logInAliasesIdentity() async {
        let (manager, mock) = await makeManager(isEntitled: true)

        await manager.logIn(accountId: "user-123")

        #expect(mock.logInCallCount == 1)
        #expect(mock.lastLogInAppUserID == "user-123")
        #expect(manager.isPurchased == true)
    }
}
