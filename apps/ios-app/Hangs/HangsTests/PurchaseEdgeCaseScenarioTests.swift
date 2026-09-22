//
//  PurchaseEdgeCaseScenarioTests.swift
//  HangsTests
//
//  #180 track B — the StoreKit edge cases (interrupted purchase, Ask to Buy,
//  failed transaction, refund, expiry, restore on a fresh device, billing
//  grace period) encoded as app-level lifecycle scenarios.
//
//  Why not SKTestSession: the StoreKit test daemon is unreachable from BOTH
//  the unit-test host and the UI-test runner on the iOS 26.4/26.5 simulator
//  when driven by `xcodebuild` (SKInternalErrorDomain Code=3, Apple FB22774836,
//  re-verified 2026-09-21 on Xcode 26.5) — see `StoreKitSessionSmokeTests`.
//  So each scenario models what StoreKit/RevenueCat hand the app (via the
//  `PurchaseService` / `PackPurchaseServiceProtocol` mocks) and asserts the
//  OUTCOME the customer sees: `StoreManager.purchaseState`, the entitlement
//  reconciler's published usage mirror, and whether the paywall shows. Never
//  raw transactions — the server mirror is the gate (#102).
//
//  Wiring mirrors `AppState`: `StoreManager.onPurchaseSuccess` bridges into
//  `QuizViewModel.notifyPremiumPurchased()`, and the reconciler's
//  `isLocallyEntitled` reads `StoreManager.isPurchased` (RC's local cache).
//

import Clocks
import Foundation
@testable import Hangs
import SwiftUI
import Testing

// MARK: - Helpers

private func makeUsage(remaining: Int, premium: Bool = false, status: String? = nil, credits: Int = 0) -> UsageInfo {
    UsageInfo(
        userId: "mock-subject",
        isPremium: premium,
        questionsUsed: 100 - remaining,
        questionsLimit: 100,
        remaining: remaining,
        resetsAt: "",
        subscriptionStatus: status ?? (premium ? "active" : "none"),
        creditBalance: credits
    )
}

private func makeQuotaLimitError() -> QuotaLimitError {
    QuotaLimitError(error: "quota_exceeded", questionsUsed: 100, questionsLimit: 100, resetsAt: "", upgradeAvailable: true)
}

/// What the store hands back when the App Store cannot complete the charge
/// (StoreKit's `purchaseFailed` / an interrupted purchase surfaces here).
private struct StoreFailure: LocalizedError {
    var errorDescription: String? { "The App Store could not complete the purchase." }
}

@MainActor
private final class Loop {
    let vm: QuizViewModel
    let network: MockNetworkService
    let purchases: MockPurchaseService
    let store: StoreManager

    /// `usage` is the server mirror at launch; `entitled` is RC's local cache.
    init(usage: UsageInfo, entitled: Bool, clock: TestClock<Duration> = TestClock()) async {
        network = Fixtures.makeFullMockNetwork()
        network.stubbedUsage = usage
        purchases = MockPurchaseService()
        purchases.stubbedIsEntitled = entitled
        store = StoreManager(purchaseService: purchases)
        let store = store
        vm = QuizViewModel(
            networkService: network,
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService(),
            isLocallyEntitled: { store.isPurchased }, // AppState's wiring
            clock: AnyClock(clock)
        )
        store.onPurchaseSuccess = { [vm] in await vm.notifyPremiumPurchased() }
        await pumpUntil(
            { self.vm.usageInfo != nil && !self.vm.entitlementReconciler.isReconciling && self.store.offerings != nil },
            "launch never settled"
        )
        await pumpUntil({ self.store.isPurchased == entitled }, "launch entitlement check never settled")
    }

    func blockStartWithQuota() {
        network.createSessionError = NetworkError.quotaLimitReached(makeQuotaLimitError())
    }

    /// A background → foreground round trip with `usage` as the server mirror
    /// the webhook left behind — settled once the reconcile has PUBLISHED it
    /// (waiting on the task flag alone can resume before the task even starts).
    func foreground(expecting usage: UsageInfo) async {
        network.stubbedUsage = usage
        vm.handleScenePhase(.background)
        vm.handleScenePhase(.active)
        await pumpUntil(
            { self.vm.usageInfo == usage && !self.vm.entitlementReconciler.isReconciling },
            "foreground reconcile never published the new usage mirror"
        )
    }
}

@Suite("StoreKit edge cases as lifecycle scenarios (#180 track B)")
@MainActor
struct PurchaseEdgeCaseScenarioTests {
    // MARK: 1. Failed transaction

    @Test("a failed transaction leaves the customer un-entitled: failed state, no server sync, paywall on the next block")
    func failedTransaction() async {
        let loop = await Loop(usage: makeUsage(remaining: 0), entitled: false)
        loop.purchases.stubbedPurchaseError = StoreFailure()
        let syncsBefore = loop.network.syncEntitlementsCallCount

        await loop.store.purchase(productID: StoreProduct.monthlySubId)

        #expect(loop.store.purchaseState == .failed(message: StoreFailure().errorDescription!), "the reason must reach the paywall — a silent failure was the #96 re-prompt loop")
        #expect(loop.store.isPurchased == false)
        #expect(loop.network.syncEntitlementsCallCount == syncsBefore, "nothing was bought — no bridge sync may fire")

        loop.blockStartWithQuota()
        await loop.vm.startNewQuiz()
        #expect(loop.vm.showPaywall == true, "still on the free tier → the quota gate still routes to the paywall")
        #expect(loop.network.syncEntitlementsCallCount == syncsBefore, "not locally entitled → no pre-paywall resync either")
    }

    // MARK: 2. Interrupted purchase, resolved later

    @Test("an interrupted purchase fails now, and the transaction StoreKit delivers later entitles the customer without a re-purchase")
    func interruptedPurchaseResolvesLater() async {
        let loop = await Loop(usage: makeUsage(remaining: 0), entitled: false)
        loop.purchases.stubbedPurchaseError = StoreFailure()

        await loop.store.purchase(productID: StoreProduct.monthlySubId)
        guard case .failed = loop.store.purchaseState else {
            Issue.record("an interrupted purchase must surface as failed, got \(loop.store.purchaseState)"); return
        }

        // StoreKit resolves the interruption out of band; RC observes the
        // transaction and pushes the entitlement through its customer-info
        // stream. The webhook lands server-side while the app is backgrounded.
        loop.purchases.emitEntitlementUpdate(EntitlementUpdate(entitlementId: StoreProduct.entitlementId, isActive: true))
        await pumpUntil({ loop.store.isPurchased }, "the entitlement stream must flip isPurchased without another purchase")
        #expect(loop.purchases.purchaseCallCount == 1, "resolution must never trigger a second charge")

        await loop.foreground(expecting: makeUsage(remaining: 100, premium: true))

        #expect(loop.vm.usageInfo?.isPremium == true, "the foreground reconcile must publish the entitlement the resolved transaction bought")
        await loop.vm.startNewQuiz()
        #expect(loop.vm.quizState == .askingQuestion, "a customer whose interrupted purchase resolved must be playable — no paywall, no re-purchase")
        #expect(loop.vm.showPaywall == false)
    }

    // MARK: 3. Ask to Buy — subscription

    @Test("Ask to Buy: a pending subscription entitles nothing until the approval lands, then needs no re-purchase")
    func askToBuySubscription() async {
        let loop = await Loop(usage: makeUsage(remaining: 0), entitled: false)
        loop.purchases.stubbedPurchaseOutcome = .pending
        let syncsBefore = loop.network.syncEntitlementsCallCount

        await loop.store.purchase(productID: StoreProduct.monthlySubId)

        #expect(loop.store.purchaseState == .pending, "the child must see 'awaiting approval', not success or failure")
        #expect(loop.store.isPurchased == false, "nothing is granted before the parent approves")
        #expect(loop.network.syncEntitlementsCallCount == syncsBefore, "a pending purchase must not fire the post-purchase bridge")

        loop.blockStartWithQuota()
        await loop.vm.startNewQuiz()
        #expect(loop.vm.showPaywall == true, "until approval the free-tier gate still applies")

        // The parent approves later; RC's stream delivers the entitlement and
        // the webhook has updated the server mirror by the next foreground.
        loop.vm.showPaywall = false
        loop.purchases.emitEntitlementUpdate(EntitlementUpdate(entitlementId: StoreProduct.entitlementId, isActive: true))
        await pumpUntil({ loop.store.isPurchased }, "approval must arrive through the entitlement stream")
        loop.network.createSessionError = nil
        await loop.foreground(expecting: makeUsage(remaining: 100, premium: true))

        #expect(loop.purchases.purchaseCallCount == 1, "approval completes the ORIGINAL purchase — never a second one")
        await loop.vm.startNewQuiz()
        #expect(loop.vm.quizState == .askingQuestion, "an approved Ask to Buy must make the quiz playable")
    }

    // MARK: 4. Ask to Buy — custom pack (pure StoreKit 2 path)

    @Test("Ask to Buy on a custom pack: no order is created while pending, and the later approval is spent without a second charge")
    func askToBuyCustomPack() async {
        // The pending purchase throws `.pending`; the sheet must explain it and
        // must not create an order the backend would try to fulfil unpaid.
        let orders = MockPackOrderService()
        let pendingPurchase = MockPackPurchaseService(purchaseResult: .failure(.pending))
        let vm = OrderPackViewModel(
            service: orders,
            purchaseService: pendingPurchase,
            adminKeyAvailable: { false },
            orderLanguages: { Language.selectableLanguages(in: LanguageAvailability.fallbackPackOrderCodes) },
            clock: AnyClock(ImmediateClock())
        )
        vm.prompt = "Ten questions about the Roman Empire"
        vm.advanceToSummary()

        await vm.submit()

        #expect(vm.state == .failed(PackPurchaseError.pending.errorDescription!, retryable: true), "the customer must read 'awaiting approval', not a generic failure")
        #expect(orders.capturedIntents.isEmpty, "no proof → no order may reach the backend")

        // The approval clears later and StoreKit delivers it on
        // `Transaction.updates` (possibly on a later launch). The listener
        // persists the proof BEFORE finishing the transaction (#138 review 3).
        let suiteName = "PurchaseEdgeCaseScenarioTests.\(UUID().uuidString)"
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        let durable = PendingPackPurchaseStore(suiteName: suiteName)
        let approved = PackPaymentProof(transactionId: "990000000000321", productId: StoreKitPackPurchaseService.productId, jws: "approved.jws")
        let captured = await StoreKitPackPurchaseService.captureAndFinish(
            store: durable, transactionId: approved.transactionId, productId: approved.productId, jws: approved.jws, finish: {}
        )
        #expect(captured)
        #expect(durable.load() == approved, "the approved charge must survive as the pending proof")

        // Next launch: the pending proof is spent first — the customer is not
        // charged again for the pack the parent just approved.
        let relaunchOrders = MockPackOrderService()
        let relaunchPurchase = MockPackPurchaseService(pending: durable.load())
        let relaunched = OrderPackViewModel(
            service: relaunchOrders,
            purchaseService: relaunchPurchase,
            adminKeyAvailable: { false },
            orderLanguages: { Language.selectableLanguages(in: LanguageAvailability.fallbackPackOrderCodes) },
            clock: AnyClock(ImmediateClock())
        )
        relaunched.prompt = "Ten questions about the Roman Empire"
        relaunched.advanceToSummary()
        await relaunched.submit()

        #expect(relaunchPurchase.purchaseCallCount == 0, "an approved, unspent transaction must be reused, never re-charged")
        #expect(relaunchOrders.capturedIntents.first?.paymentProof == approved)
        #expect(relaunchPurchase.pendingProof() == nil, "an accepted order spends the proof")
    }

    // MARK: 5. Refund mid-session

    @Test("a refund revokes the entitlement mid-session: the next quota block shows the paywall with no resync attempt")
    func refundRevokesEntitlement() async {
        let loop = await Loop(usage: makeUsage(remaining: 100, premium: true), entitled: true)
        #expect(loop.store.isPurchased == true, "precondition: a paying subscriber")

        // App Store refund → RC revokes the entitlement (stream) and the
        // server mirror drops back to the free tier via the webhook.
        loop.purchases.emitEntitlementUpdate(EntitlementUpdate(entitlementId: StoreProduct.entitlementId, isActive: false))
        await pumpUntil({ !loop.store.isPurchased }, "the revocation must reach isPurchased through the entitlement stream")
        await loop.foreground(expecting: makeUsage(remaining: 0, status: "refunded"))
        #expect(loop.vm.usageInfo?.isPremium == false, "the reconcile must publish the revoked state")

        let syncsBefore = loop.network.syncEntitlementsCallCount
        loop.blockStartWithQuota()
        await loop.vm.startNewQuiz()

        #expect(loop.vm.showPaywall == true, "a refunded customer is back on the free tier — the gate must route to the paywall")
        #expect(loop.vm.quotaLimitError != nil)
        #expect(loop.network.syncEntitlementsCallCount == syncsBefore, "RC no longer reports the entitlement → no pre-paywall resync window, the paywall shows at once")
    }

    // MARK: 6. Expiry (cold start after the subscription lapsed)

    @Test("an expired subscription on a cold start reconciles to the free tier and the paywall shows immediately on a block")
    func expiredSubscriptionAtLaunch() async {
        // StoreKit's accelerated expiry has run its course before this launch:
        // RC's cache no longer holds the entitlement and the server mirror
        // reports the lapsed status with the free allowance.
        let loop = await Loop(usage: makeUsage(remaining: 30, status: "expired"), entitled: false)

        #expect(loop.vm.usageInfo?.isPremium == false)
        #expect(loop.vm.usageInfo?.subscriptionStatus == "expired", "the mirror must carry the lapsed status the Home card explains")
        #expect(loop.vm.usageLoadState == .loaded)
        #expect(loop.store.isPurchased == false)

        let syncsAtLaunch = loop.network.syncEntitlementsCallCount
        loop.blockStartWithQuota()
        await loop.vm.startNewQuiz()

        #expect(loop.vm.showPaywall == true)
        #expect(loop.network.syncEntitlementsCallCount == syncsAtLaunch, "expired → nothing to resync; the paywall must not hang for the window")
    }

    // MARK: 7. Restore on a fresh device

    @Test("restore on a fresh device: the subscription comes back, the server confirms it, and the quiz is playable without a purchase")
    func restoreOnFreshDevice() async {
        // A new install: no RC cache, the server mirror knows only the account's
        // free allowance until the restore re-syncs it.
        let loop = await Loop(usage: makeUsage(remaining: 0), entitled: false)
        loop.blockStartWithQuota()
        await loop.vm.startNewQuiz()
        #expect(loop.vm.showPaywall == true, "precondition: the fresh device is blocked at the gate")

        loop.purchases.stubbedIsEntitled = true // StoreKit restore → RC re-derives the entitlement
        loop.network.stubbedUsage = makeUsage(remaining: 100, premium: true)
        loop.network.createSessionError = nil
        let syncsBefore = loop.network.syncEntitlementsCallCount
        await loop.store.restorePurchases()

        #expect(loop.store.purchaseState == .success(productID: nil), "a restore that brought the subscription back is a real success, not nothing-to-restore")
        #expect(loop.store.isPurchased == true)
        #expect(loop.network.syncEntitlementsCallCount > syncsBefore, "restore must reconcile with the server — RC's receipt alone never lifts the gate")
        #expect(loop.purchases.purchaseCallCount == 0, "restore never charges")
        #expect(loop.vm.usageInfo?.isPremium == true)

        loop.vm.showPaywall = false
        await loop.vm.startNewQuiz()
        #expect(loop.vm.quizState == .askingQuestion, "a restored subscriber must be playable on the new device")
    }

    // MARK: 8. Billing grace period

    @Test("billing grace period: RC still entitles, so a lagging 429 gets one bounded resync and the paywall stays away while the server honours the grace")
    func billingGracePeriod() async {
        let clock = TestClock()
        let loop = await Loop(usage: makeUsage(remaining: 100, premium: true, status: "grace_period"), entitled: true, clock: clock)
        #expect(loop.store.isPurchased == true, "precondition: RC keeps the entitlement active during billing retry")

        // The server mirror momentarily denies (a webhook race during billing
        // retry) and the start hits a 429 — but RC's local entitlement earns
        // the bounded pre-paywall resync, after which the mirror confirms the
        // grace period is still honoured.
        let syncsBefore = loop.network.syncEntitlementsCallCount
        loop.blockStartWithQuota()
        await loop.vm.startNewQuiz()

        #expect(loop.network.syncEntitlementsCallCount == syncsBefore + 1, "locally entitled → exactly one resync attempt before deciding on the paywall")
        #expect(loop.vm.showPaywall == false, "the server still honours the grace period — a customer in billing retry must not be thrown at the paywall")
        #expect(loop.vm.quotaLimitError == nil)

        // Grace ends unpaid: RC drops the entitlement, the mirror lapses — the
        // next block shows the paywall immediately, no resync window.
        loop.purchases.emitEntitlementUpdate(EntitlementUpdate(entitlementId: StoreProduct.entitlementId, isActive: false))
        await pumpUntil({ !loop.store.isPurchased }, "grace expiry must revoke through the entitlement stream")
        await loop.foreground(expecting: makeUsage(remaining: 0, status: "expired"))
        let syncsAfterLapse = loop.network.syncEntitlementsCallCount
        await loop.vm.startNewQuiz()

        #expect(loop.vm.showPaywall == true, "once the grace period lapses unpaid the gate applies")
        #expect(loop.network.syncEntitlementsCallCount == syncsAfterLapse, "no local entitlement → no resync window")
    }
}
