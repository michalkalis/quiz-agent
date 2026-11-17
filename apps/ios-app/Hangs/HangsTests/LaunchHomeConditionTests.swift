//
//  LaunchHomeConditionTests.swift
//  HangsTests
//
//  #235.2 (flow × condition, app launch and Home row). At launch the app asks
//  the server for the quota card (/usage), syncs purchases (/entitlements/sync)
//  and reads its switches (/app-config). None of it may hold Home up: the
//  quota card shows loading, then numbers or a Retry; a slow purchase sync
//  never delays the card; the switches fail open. Failures that already have
//  tests: EntitlementReconcileTests, AppConfigStoreTests, HomeFreePlanCardTests,
//  MyPacksViewModelTests and HomePacksSectionTests.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@Suite("App launch and Home on a bad network (#235.2)")
@MainActor
struct LaunchHomeConditionTests {
    private func makeVM(_ network: MockNetworkService, clock: TestClock<Duration>) -> QuizViewModel {
        network.networkClock = AnyClock(clock)
        return QuizViewModel(
            networkService: network,
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService(),
            clock: AnyClock(clock)
        )
    }

    // WHY: the quota card is the first thing on Home. Whatever the network
    // does to /usage, its loading state must end in the Retry card after the
    // bounded three tries, never spin forever (the #FIX2 card that vanished).
    @Test("a /usage call that never succeeds ends on the Retry card after three tries", arguments: [
        NetworkCondition.timeout, .offline, .dropped(after: .seconds(5)), .serverError(statusCode: 500), .malformed,
    ])
    func usageFailureEndsOnRetryCard(condition: NetworkCondition) async {
        let clock = TestClock()
        let network = Fixtures.makeFullMockNetwork()
        network.setNetworkCondition(condition, for: [.getUsage])
        let vm = makeVM(network, clock: clock)
        #expect(vm.usageLoadState == .loading, "the card must show it is loading")

        await advanceUntil(clock, limit: .seconds(120)) { vm.usageLoadState == .failed }

        #expect(network.getUsageCallCount == 3)
        #expect(vm.usageInfo == nil)
    }

    // WHY: the purchase sync runs at every launch and can hang on a bad
    // network for up to three request timeouts. Home's own /usage fetch must
    // not wait behind it, or the quota card would spin for a minute and more.
    @Test("a purchase sync that hangs does not hold up the quota card")
    func hangingSyncDoesNotHoldUsage() async {
        let clock = TestClock()
        let network = Fixtures.makeFullMockNetwork()
        network.setNetworkCondition(.timeout, for: [.syncEntitlements])
        let vm = makeVM(network, clock: clock)
        await pumpUntil { network.syncEntitlementsCallCount == 1 }

        await vm.refreshUsage() // HomeView.onAppear

        #expect(vm.usageLoadState == .loaded)
        #expect(vm.usageInfo != nil)
    }

    // WHY: the app switches (maintenance, forced update, orders) arrive with
    // a request that may take seconds. Until it answers the app runs on the
    // permissive defaults, so a slow server can never lock the player out.
    @Test("while the app switches are on their way the app stays fully usable")
    func slowAppConfigKeepsAppUsable() async {
        let hold = NetworkHold()
        let store = AppConfigStore(
            fetch: {
                try await hold.wait()
                return RemoteAppConfig(minVersionAppStore: nil, minVersionTestflight: nil, ordersEnabled: false, notice: nil)
            },
            defaults: UserDefaults(suiteName: "LaunchHomeConditionTests.\(UUID().uuidString)")!,
            appVersion: "1.0",
            isTestFlight: false,
            isAppStoreBuild: false
        )
        let refresh = Task { await store.refresh() }
        await pumpUntil { hold.heldCount == 1 }

        #expect(!store.updateRequired)
        #expect(!store.maintenance)
        #expect(store.ordersEnabled)

        hold.release()
        await refresh.value
        #expect(!store.ordersEnabled, "the switch that arrived late was not applied")
    }
}
