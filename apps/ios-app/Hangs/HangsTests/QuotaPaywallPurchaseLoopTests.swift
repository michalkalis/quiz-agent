//
//  QuotaPaywallPurchaseLoopTests.swift
//  HangsTests
//
//  THE money loop, end to end at the view-model layer: quota exhausted → 429 →
//  paywall → purchase/restore → entitlement refresh → playable again.
//
//  Every leg of it had tests; the LOOP had none (#133 audit named gap). That is
//  the gap that matters, because the failure the founder actually hit on device
//  (#96 S1: paid, no entitlement, re-prompt loop) lives between the legs — the
//  paywall showing again after a successful purchase, or a confirmed purchase
//  that still can't start a quiz. The WHY of every assertion below: a customer
//  who has just paid must end up in a PLAYABLE state, not back at the paywall.
//
//  Wiring mirrors `AppState`: `StoreManager.onPurchaseSuccess` is the real
//  bridge to `QuizViewModel.notifyPremiumPurchased()`, so this drives the same
//  chain the app does (StoreKit itself is `MockPurchaseService`; the server's
//  side of the gate is `MockNetworkService`).
//

import Foundation
@testable import Hangs
import Testing

@MainActor
private func makeUsage(remaining: Int, premium: Bool = false, credits: Int = 0) -> UsageInfo {
    UsageInfo(
        userId: "mock-subject",
        isPremium: premium,
        questionsUsed: 100 - remaining,
        questionsLimit: 100,
        remaining: remaining,
        resetsAt: "",
        subscriptionStatus: premium ? "active" : "none",
        creditBalance: credits
    )
}

private func makeQuotaLimitError() -> QuotaLimitError {
    QuotaLimitError(error: "quota_exceeded", questionsUsed: 100, questionsLimit: 100, resetsAt: "", upgradeAvailable: true)
}

@Suite("Quota → paywall → purchase → playable loop (#133 named gap)")
@MainActor
struct QuotaPaywallPurchaseLoopTests {
    /// VM + StoreManager wired to each other exactly as `AppState` wires them.
    private func makeLoop(
        purchaseOutcome: PurchaseOutcome = .success(unlimitedActive: true),
        isEntitledAfterPurchase: Bool = true
    ) async -> (QuizViewModel, MockNetworkService, StoreManager) {
        let network = Fixtures.makeFullMockNetwork()
        network.stubbedUsage = makeUsage(remaining: 0) // the exhausted free tier
        let vm = QuizViewModel(
            networkService: network,
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            isLocallyEntitled: { false } // RC has nothing cached yet — no pre-paywall resync
        )
        // Deterministic time: never wait out a production retry backoff.
        vm.entitlementReconciler.backoffSleep = SleepRecorder().sleep

        let purchases = MockPurchaseService()
        purchases.stubbedPurchaseOutcome = purchaseOutcome
        purchases.stubbedIsEntitled = isEntitledAfterPurchase
        let store = StoreManager(purchaseService: purchases)
        store.onPurchaseSuccess = { await vm.notifyPremiumPurchased() } // AppState's bridge

        // Settle the launch reconcile completely — while its task is alive, a
        // later refresh joins it instead of issuing its own fetch.
        await pumpUntil(
            { vm.usageInfo != nil && !vm.entitlementReconciler.isReconciling },
            "launch reconcile never settled"
        )
        return (vm, network, store)
    }

    @Test("a 429-blocked start, a subscription purchase, and the quiz is playable again")
    func exhaustedQuotaThroughPurchaseBackToPlayable() async {
        let (vm, network, store) = await makeLoop()
        #expect(vm.usageInfo?.remaining == 0, "precondition: the free allowance is spent")

        // 1. The server refuses the start with the quota 429.
        network.createSessionError = NetworkError.quotaLimitReached(makeQuotaLimitError())
        await vm.startNewQuiz()

        #expect(vm.showPaywall == true, "an exhausted quota must route to the paywall, not an error screen")
        #expect(vm.quotaLimitError != nil, "the paywall needs the limit error to show 'limit reached' copy, not the generic pitch")
        #expect(vm.quizState == .idle, "the blocked start must unwind to idle, never strand .startingQuiz behind the sheet")

        // 2. The customer pays. The mock store completes; the server mirror now
        //    reports the subscription (the webhook/sync side of the gate), and
        //    the quota gate stops firing.
        network.stubbedUsage = makeUsage(remaining: 100, premium: true)
        network.createSessionError = nil
        let syncsBeforePurchase = network.syncEntitlementsCallCount
        await store.purchase(productID: StoreProduct.monthlySubId)

        #expect(
            store.purchaseState == .success(productID: StoreProduct.monthlySubId),
            "the bridge confirmed server-side entitlement, so this is a real .success — .activating here is the 'I paid but it still limits me' state"
        )
        #expect(
            network.syncEntitlementsCallCount > syncsBeforePurchase,
            "the purchase must drive /entitlements/sync — RC's local receipt alone never lifts the server quota gate"
        )
        #expect(vm.usageInfo?.isPremium == true, "the published mirror must carry the entitlement the purchase just bought")

        // 3. The paywall closes (PaywallView owns the dismissal on .success via
        //    its `.task(id:)`) and the driver retries.
        vm.showPaywall = false
        await vm.startNewQuiz()

        #expect(vm.quizState == .askingQuestion, "a paying customer must land back in a playable quiz")
        #expect(vm.currentQuestion != nil, "…with an actual question to answer")
        #expect(vm.showPaywall == false, "the paywall must not re-present after a confirmed purchase (#96 S1's re-prompt loop)")
    }

    @Test("a pack-only restore recovers credits and reopens the quiz, though isPurchased stays false")
    func packOnlyRestoreReopensTheQuiz() async {
        // Consumable packs never flip RC's `isPurchased`, so the ONLY signal
        // that a pack buyer was recovered is the server mirror's credit balance
        // (#102 finding 3) — a restore that trusts `isPurchased` tells a paying
        // customer "nothing to restore".
        let (vm, network, store) = await makeLoop(
            purchaseOutcome: .success(unlimitedActive: false),
            isEntitledAfterPurchase: false
        )

        network.createSessionError = NetworkError.quotaLimitReached(makeQuotaLimitError())
        await vm.startNewQuiz()
        #expect(vm.showPaywall == true)

        // The server re-derives the pack credits during the sync.
        network.stubbedUsage = makeUsage(remaining: 0, premium: false, credits: 5)
        network.createSessionError = nil
        await store.restorePurchases()

        #expect(store.isPurchased == false, "no subscription came back — this recovery is credits only")
        #expect(
            store.purchaseState == .success(productID: nil),
            "server-recovered credits are a real restore, not .nothingToRestore"
        )
        #expect(vm.usageInfo?.creditBalance == 5, "the recovered credits must reach the published mirror the UI reads")

        vm.showPaywall = false
        await vm.startNewQuiz()
        #expect(vm.quizState == .askingQuestion, "recovered credits must make the quiz playable again")
    }

    @Test("a purchase the server never confirms keeps the customer informed instead of silently 'succeeding'")
    func unconfirmedPurchaseDoesNotClaimSuccess() async {
        // The other half of the loop's contract: when the sync/webhook has NOT
        // landed, the app must say so (.activating) rather than claim success —
        // and it must not fabricate an entitlement client-side.
        let (vm, network, store) = await makeLoop()
        network.syncEntitlementsError = NetworkError.invalidResponse // the bridge cannot land
        network.stubbedUsage = makeUsage(remaining: 0) // …and the mirror still shows the free tier spent

        await store.purchase(productID: StoreProduct.monthlySubId)

        #expect(
            store.purchaseState == .activating(productID: StoreProduct.monthlySubId),
            "an unconfirmed purchase must land in .activating — claiming .success is what produced the re-prompt loop"
        )
        #expect(vm.usageInfo?.isPremium == false, "the client never grants entitlement itself; the server mirror stays the gate")
    }
}
