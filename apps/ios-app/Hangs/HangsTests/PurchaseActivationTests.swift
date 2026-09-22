//
//  PurchaseActivationTests.swift
//  HangsTests
//
//  #102 finding 4: RC's `customerInfoStream` flips `isPurchased`/`purchaseState`
//  the instant a purchase completes, while the server `/usage` mirror (the
//  actual quota gate) only agrees once the post-purchase sync bridge lands.
//  Before this fix, `StoreManager.purchase()` published `.success` on RC's
//  say-so alone — "I paid but it still limits me" if the bridge hadn't
//  actually confirmed yet. These pin:
//    • bridge NOT yet confirmed → `.activating`, never `.success`;
//    • bridge already confirmed → `.success` directly, with no transient
//      `.activating` published along the way (verified via a Combine spy,
//      not timing);
//    • `QuizViewModel.notifyPremiumPurchased()` (the bridge itself) reuses the
//      #102 finding-1 bounded-retry helper instead of a single unguarded
//      attempt, so a transient sync failure still gets a fair shot at landing
//      on `.success` within the purchase session.
//

import Clocks
import Combine
import Foundation
@testable import Hangs
import Testing

@MainActor
private func makeManager(
    isEntitled: Bool,
    purchaseOutcome: PurchaseOutcome
) async -> StoreManager {
    let mock = MockPurchaseService()
    mock.stubbedIsEntitled = isEntitled
    mock.stubbedPurchaseOutcome = purchaseOutcome
    let manager = StoreManager(purchaseService: mock)
    // Drain the init Tasks (loadOfferings + checkPurchaseStatus).
    await Task.yield()
    await Task.yield()
    return manager
}

@Suite("Purchase activation state (#102 finding 4)")
@MainActor
struct PurchaseActivationTests {
    @Test("subscription purchase success without server confirmation lands in .activating, not .success")
    func subscriptionPurchaseUnconfirmedLandsInActivating() async {
        let manager = await makeManager(isEntitled: true, purchaseOutcome: .success(unlimitedActive: true))
        // Bridge ran (sync + usage refresh attempted) but the server mirror
        // still doesn't show premium/credits — e.g. offline sync, or the
        // webhook genuinely hasn't landed yet.
        manager.onPurchaseSuccess = { false }

        await manager.purchase(productID: StoreProduct.monthlySubId)

        #expect(manager.purchaseState == .activating(productID: StoreProduct.monthlySubId))
        #expect(manager.isPurchased == true, "RC's own receipt check still reflects the entitlement locally")
    }

    @Test("pack purchase success without server confirmation lands in .activating with the pack product id")
    func packPurchaseUnconfirmedLandsInActivating() async {
        let manager = await makeManager(isEntitled: false, purchaseOutcome: .success(unlimitedActive: false))
        manager.onPurchaseSuccess = { false }

        await manager.purchase(productID: StoreProduct.packId)

        #expect(manager.purchaseState == .activating(productID: StoreProduct.packId))
        #expect(manager.isPurchased == false, "consumable packs never flip the subscription flag")
    }

    @Test("purchase success with the server already agreeing never flashes .activating")
    func purchaseAlreadyConfirmedNeverFlashesActivating() async {
        let manager = await makeManager(isEntitled: true, purchaseOutcome: .success(unlimitedActive: true))
        manager.onPurchaseSuccess = { true } // server mirror already caught up by the time the bridge returns

        var observedStates: [PurchaseState] = []
        let cancellable = manager.$purchaseState.sink { observedStates.append($0) }
        await manager.purchase(productID: StoreProduct.monthlySubId)
        cancellable.cancel()

        #expect(manager.purchaseState == .success(productID: StoreProduct.monthlySubId))
        #expect(
            !observedStates.contains(.activating(productID: StoreProduct.monthlySubId)),
            "the server already agreeing must go straight to .success — no transient activating flash"
        )
    }

    // MARK: - notifyPremiumPurchased bounded retry (the bridge behind onPurchaseSuccess)

    @Test("notifyPremiumPurchased retries a failed sync with backoff before reporting the final outcome")
    func notifyPremiumPurchasedRetriesBeforeConfirming() async {
        let mock = Fixtures.makeFullMockNetwork()
        // Deterministic time (#133 audit, #180 track A): the bounded backoff
        // runs on this clock, so the ~0.6 s of real sleeps are DRIVEN here
        // rather than waited out.
        let clock = TestClock()
        let vm = QuizViewModel(
            networkService: mock,
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService(),
            clock: AnyClock(clock)
        )
        // Drain the launch-time reconcile (#102 finding 1, same view model
        // init) first so it can't consume the failure budget set below —
        // isolates the assertion to notifyPremiumPurchased's own retry pass.
        await vm.entitlementReconciler.reconcileEntitlements()
        let baseline = mock.syncEntitlementsCallCount

        mock.syncEntitlementsFailuresBeforeSuccess = 2 // fails twice, succeeds on the 3rd bounded attempt
        mock.stubbedUsage = UsageInfo(
            userId: "mock-subject", isPremium: true, questionsUsed: 0,
            questionsLimit: nil, remaining: nil,
            resetsAt: "", subscriptionStatus: "active", creditBalance: 0
        )

        let purchase = Task { await vm.notifyPremiumPurchased() }

        // The retries must be SPACED (the shared bounded-backoff helper), not an
        // instant re-hammer: each attempt is released only by advancing past the
        // shipped 0.2 s, then 0.4 s, boundary.
        await pumpUntil({ mock.syncEntitlementsCallCount == baseline + 1 }, "the post-purchase sync never fired")
        await clock.advance(by: .milliseconds(190))
        #expect(mock.syncEntitlementsCallCount == baseline + 1, "the 2nd attempt fired before the 0.2 s backoff elapsed")
        await clock.advance(by: .milliseconds(11))
        await pumpUntil({ mock.syncEntitlementsCallCount == baseline + 2 }, "the 2nd attempt never fired once its backoff elapsed")
        await clock.advance(by: .milliseconds(390))
        #expect(mock.syncEntitlementsCallCount == baseline + 2, "the 3rd attempt fired before the doubled 0.4 s backoff elapsed")
        await clock.advance(by: .milliseconds(11))

        let confirmed = await purchase.value

        #expect(confirmed == true, "the bounded retry must still land on the server-confirmed outcome")
        #expect(mock.syncEntitlementsCallCount - baseline >= 3, "a failing sync must retry (#102 finding 1's helper), not give up on the first attempt")
    }
}
