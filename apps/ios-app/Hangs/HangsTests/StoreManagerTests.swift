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
    purchaseOutcome: PurchaseOutcome = .success(unlimitedActive: true),
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
        let (manager, _) = await makeManager(offerings: .sample, isEntitled: true, purchaseOutcome: .success(unlimitedActive: true))
        await manager.purchase(productID: StoreProduct.monthlySubId)

        #expect(manager.isPurchased == true)
        #expect(manager.purchaseError == nil)
        #expect(manager.isLoading == false)
    }

    // MARK: 4. purchase(pack) .success — does NOT set isPurchased (consumable, not a sub)

    @Test("purchase pack success does not set isPurchased")
    func purchasePackSuccessDoesNotSetIsPurchased() async {
        let (manager, _) = await makeManager(offerings: .sample, isEntitled: false, purchaseOutcome: .success(unlimitedActive: false))
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

    // MARK: 13. Purchase outcome is a first-class event (#96 P1)
    //
    // The founder's device bug: a pack purchase succeeded end-to-end
    // (Apple + RC + webhook + credits granted) but the app gave zero feedback,
    // because ALL post-purchase behaviour hung off the subscription-only
    // `isPurchased` flag. These pin the outcome-keyed contract: purchaseState
    // reflects every outcome, and onPurchaseSuccess (the entitlement-sync +
    // usage-refresh bridge) fires for ANY successful purchase — pack included.

    @Test("pack purchase success publishes success state and fires onPurchaseSuccess")
    func packPurchaseSuccessFiresBridge() async {
        let (manager, _) = await makeManager(isEntitled: false, purchaseOutcome: .success(unlimitedActive: false))
        var bridgeFired = false
        manager.onPurchaseSuccess = { bridgeFired = true; return true }

        await manager.purchase(productID: StoreProduct.packId)

        #expect(manager.purchaseState == .success(productID: StoreProduct.packId))
        #expect(bridgeFired == true)
        #expect(manager.isPurchased == false)  // consumable never flips the sub flag
    }

    @Test("subscription purchase success fires onPurchaseSuccess")
    func subscriptionPurchaseSuccessFiresBridge() async {
        let (manager, _) = await makeManager(isEntitled: true, purchaseOutcome: .success(unlimitedActive: true))
        var bridgeFired = false
        manager.onPurchaseSuccess = { bridgeFired = true; return true }

        await manager.purchase(productID: StoreProduct.annualSubId)

        #expect(manager.purchaseState == .success(productID: StoreProduct.annualSubId))
        #expect(bridgeFired == true)
    }

    @Test("subscription success without entitlement fails loud, no bridge")
    func subscriptionSuccessWithoutEntitlementFailsLoud() async {
        // The store sheet completed but RC returned no active entitlement —
        // silent success here was the founder's password re-prompt loop.
        let (manager, _) = await makeManager(isEntitled: false, purchaseOutcome: .success(unlimitedActive: false))
        var bridgeFired = false
        manager.onPurchaseSuccess = { bridgeFired = true; return true }

        await manager.purchase(productID: StoreProduct.monthlySubId)

        guard case .failed = manager.purchaseState else {
            Issue.record("expected .failed, got \(manager.purchaseState)")
            return
        }
        #expect(manager.purchaseError != nil)
        #expect(bridgeFired == false)
    }

    @Test("cancelled and pending purchases publish their states, no bridge")
    func cancelledAndPendingPublishStates() async {
        let (manager, _) = await makeManager(purchaseOutcome: .userCancelled)
        var bridgeFired = false
        manager.onPurchaseSuccess = { bridgeFired = true; return true }

        await manager.purchase(productID: StoreProduct.monthlySubId)
        #expect(manager.purchaseState == .cancelled)

        let (pendingManager, _) = await makeManager(purchaseOutcome: .pending)
        pendingManager.onPurchaseSuccess = { bridgeFired = true; return true }
        await pendingManager.purchase(productID: StoreProduct.monthlySubId)
        #expect(pendingManager.purchaseState == .pending)
        #expect(bridgeFired == false)
    }

    @Test("thrown purchase error publishes failed state")
    func thrownErrorPublishesFailedState() async {
        let (manager, _) = await makeManager(purchaseError: StoreError.failedVerification)
        await manager.purchase(productID: StoreProduct.monthlySubId)

        guard case .failed = manager.purchaseState else {
            Issue.record("expected .failed, got \(manager.purchaseState)")
            return
        }
    }

    @Test("entitled restore publishes success and fires onPurchaseSuccess")
    func entitledRestoreFiresBridge() async {
        let (manager, _) = await makeManager(isEntitled: true)
        var bridgeFired = false
        manager.onPurchaseSuccess = { bridgeFired = true; return true }

        await manager.restorePurchases()

        #expect(manager.purchaseState == .success(productID: nil))
        #expect(bridgeFired == true)
    }

    // MARK: 14. Pack-only recovery via restore (#102 finding 3)
    //
    // StoreKit has no restore mechanism for consumables — a pack buyer's
    // credits only come back through the server re-deriving them from RC's
    // history (`POST /entitlements/sync`). Before this fix, `restorePurchases()`
    // gated that call on `isPurchased`, which a pack purchase never sets — so
    // a pack-only buyer was told "nothing to restore" even though the server
    // could have recovered their credits. These pin: the bridge always fires
    // (regardless of subscription entitlement), and the outcome is keyed on
    // what the bridge reports came back, not on `isPurchased` alone.

    @Test("restore reconciles with the server even when RC reports no subscription entitlement")
    func restoreAlwaysReconcilesRegardlessOfEntitlement() async {
        let (manager, _) = await makeManager(isEntitled: false)
        let network = MockNetworkService()
        network.stubbedUsage = UsageInfo(
            userId: "mock-subject", isPremium: false, questionsUsed: 30,
            questionsLimit: 100, remaining: 70,
            resetsAt: ISO8601DateFormatter().string(from: Date()),
            subscriptionStatus: "none", creditBalance: 0
        )
        manager.onPurchaseSuccess = {
            try? await network.syncEntitlements()
            let usage = try? await network.getUsage()
            return (usage?.isPremium ?? false) || (usage?.creditBalance ?? 0) > 0
        }

        await manager.restorePurchases()

        // Sync + usage refresh both ran, unconditionally on the subscription state.
        #expect(network.syncEntitlementsCallCount == 1)
        #expect(network.getUsageCallCount == 1)
    }

    @Test("un-entitled restore with pack credits recovered via server reconciliation reports success")
    func unentitledRestoreWithRecoveredCreditsReportsSuccess() async {
        let (manager, _) = await makeManager(isEntitled: false)
        var bridgeFired = false
        // Simulates the server reconciliation surfacing a non-zero pack
        // credit balance — `isPurchased` stays false the whole time.
        manager.onPurchaseSuccess = { bridgeFired = true; return true }

        await manager.restorePurchases()

        #expect(manager.purchaseState == .success(productID: nil))
        #expect(bridgeFired == true)
        #expect(manager.isPurchased == false)
    }

    @Test("un-entitled restore with nothing recovered reports nothing-to-restore, not success")
    func unentitledRestoreWithNothingRecoveredReportsNothingToRestore() async {
        let (manager, _) = await makeManager(isEntitled: false)
        var bridgeFired = false
        // Server reconciliation ran but found no subscription and no credits.
        manager.onPurchaseSuccess = { bridgeFired = true; return false }

        await manager.restorePurchases()

        // Must be visible — a silent no-op restore is the same "no response"
        // defect class this issue fixes — but it must not claim success when
        // nothing actually changed.
        #expect(manager.purchaseState == .nothingToRestore)
        #expect(bridgeFired == true)
    }

    @Test("resetPurchaseState clears a finished attempt back to idle")
    func resetPurchaseStateClearsFinishedAttempt() async {
        let (manager, _) = await makeManager(purchaseOutcome: .userCancelled)
        await manager.purchase(productID: StoreProduct.monthlySubId)
        #expect(manager.purchaseState == .cancelled)

        manager.resetPurchaseState()

        #expect(manager.purchaseState == .idle)
        #expect(manager.purchaseError == nil)
    }
}
