//
//  PurchaseConditionTests.swift
//  HangsTests
//
//  #235.2 (flow × condition, purchase and restore row). After the App Store
//  charges, the app asks our server to confirm (`/entitlements/sync`, three
//  tries) before it says "done". That confirmation is the fragile part: on a
//  bad network the paywall must keep saying the purchase is being finished,
//  then land on "activating" (the purchase is kept, the server catches up
//  later), never spin forever, never charge again. The store sheet's own
//  failures, the offline paywall, Ask to Buy and late store transactions are
//  in StoreManagerTests, PaywallViewInspectorTests, PurchaseEdgeCaseScenarioTests
//  and QuotaPaywallPurchaseLoopTests.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@Suite("Purchase and restore on a bad network (#235.2)")
@MainActor
struct PurchaseConditionTests {
    private struct Loop {
        let vm: QuizViewModel
        let network: MockNetworkService
        let purchases: MockPurchaseService
        let store: StoreManager
    }

    private let clock = TestClock<Duration>()

    private static func usage(premium: Bool) -> UsageInfo {
        UsageInfo(
            userId: "mock-subject", isPremium: premium, questionsUsed: 100, questionsLimit: 100,
            remaining: 0, resetsAt: "", subscriptionStatus: premium ? "active" : "none", creditBalance: 0
        )
    }

    /// Quiz model and store wired as AppState wires them, the launch reconcile settled.
    private func makeLoop(entitledAfterPurchase: Bool = true) async -> Loop {
        let network = Fixtures.makeFullMockNetwork()
        network.stubbedUsage = Self.usage(premium: false)
        network.networkClock = AnyClock(clock)
        let vm = QuizViewModel(
            networkService: network,
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService(),
            isLocallyEntitled: { false },
            clock: AnyClock(clock)
        )
        let purchases = MockPurchaseService()
        purchases.stubbedIsEntitled = entitledAfterPurchase
        let store = StoreManager(purchaseService: purchases)
        store.onPurchaseSuccess = { await vm.notifyPremiumPurchased() }
        await pumpUntil({ vm.usageInfo != nil && !vm.entitlementReconciler.isReconciling }, "launch reconcile never settled")
        return Loop(vm: vm, network: network, purchases: purchases, store: store)
    }

    // WHY: the store has charged; only our server's confirmation fails. The
    // paywall must end in "activating" after the bounded tries (the player
    // keeps the subscription the store reports, the server catches up on the
    // next launch), with one charge and no endless "purchasing".
    @Test("a charged purchase whose server confirmation fails lands in activating, charged once", arguments: [
        NetworkCondition.timeout, .offline, .dropped(after: .seconds(2)), .serverError(statusCode: 500), .malformed,
    ])
    func failedConfirmationLandsInActivating(condition: NetworkCondition) async {
        let loop = await makeLoop()
        let syncsBefore = loop.network.syncEntitlementsCallCount
        loop.network.setNetworkCondition(condition, for: [.syncEntitlements])
        let purchase = Task { await loop.store.purchase(productID: StoreProduct.monthlySubId) }

        await advanceUntil(clock, limit: .seconds(150)) {
            loop.store.purchaseState == .activating(productID: StoreProduct.monthlySubId)
        }
        await purchase.value

        #expect(loop.store.purchaseState == .activating(productID: StoreProduct.monthlySubId))
        #expect(loop.store.isPurchased, "the subscription the store charged for was not kept")
        #expect(loop.purchases.purchaseCallCount == 1)
        #expect(loop.network.syncEntitlementsCallCount == syncsBefore + 3)
    }

    // WHY: a slow confirmation keeps the paywall saying the purchase is being
    // finished; a second tap or closing and reopening the paywall meanwhile
    // must neither charge again nor wipe that state, and the answer, when it
    // comes, still unlocks the player.
    @Test("a slow confirmation keeps purchasing on screen, takes no second charge, then succeeds")
    func slowConfirmationThenSuccess() async {
        let loop = await makeLoop()
        let hold = loop.network.hold(.syncEntitlements)
        let purchase = Task { await loop.store.purchase(productID: StoreProduct.monthlySubId) }
        await pumpUntil { hold.heldCount == 1 }

        #expect(loop.store.purchaseState == .purchasing(productID: StoreProduct.monthlySubId))
        await loop.store.purchase(productID: StoreProduct.monthlySubId)
        await loop.store.restorePurchases()
        loop.store.resetPurchaseState() // the paywall closed and opened again
        #expect(loop.purchases.purchaseCallCount == 1, "a second tap charged again")
        #expect(loop.purchases.restoreCallCount == 0)
        #expect(loop.store.purchaseState == .purchasing(productID: StoreProduct.monthlySubId))

        loop.network.stubbedUsage = Self.usage(premium: true)
        hold.release()
        await purchase.value
        #expect(loop.store.purchaseState == .success(productID: StoreProduct.monthlySubId))
        #expect(loop.vm.usageInfo?.isPremium == true)
    }

    // WHY: restore on a dead network ends, never spins. Today a buyer whose
    // purchase only the server can find (a question pack) is then told there
    // is nothing to restore, not that the server was unreachable (founder
    // case F6). Pinned: it ends, it is safe (nothing charged), and Restore can
    // be tapped again.
    @Test("restore with the server unreachable ends, and can be tapped again")
    func restoreWithServerUnreachableEnds() async {
        let loop = await makeLoop(entitledAfterPurchase: false)
        loop.network.setNetworkCondition(.offline, for: [.syncEntitlements, .getUsage])
        let restore = Task { await loop.store.restorePurchases() }

        await advanceUntil(clock, limit: .seconds(30)) { loop.store.purchaseState == .nothingToRestore }
        await restore.value

        #expect(loop.store.purchaseState == .nothingToRestore)
        #expect(loop.purchases.purchaseCallCount == 0)
        loop.network.setNetworkCondition(nil, for: [.syncEntitlements, .getUsage])
        loop.network.stubbedUsage = UsageInfo(
            userId: "mock-subject", isPremium: false, questionsUsed: 100, questionsLimit: 100,
            remaining: 0, resetsAt: "", subscriptionStatus: "none", creditBalance: 100
        )
        await loop.store.restorePurchases()
        #expect(loop.store.purchaseState == .success(productID: nil), "a second Restore on a good network found nothing")
    }
}
