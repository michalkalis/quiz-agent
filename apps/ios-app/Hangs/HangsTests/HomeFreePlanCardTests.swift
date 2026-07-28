//
//  HomeFreePlanCardTests.swift
//  HangsTests
//
//  #87 (directive G2): Home shows the free-plan quota — remaining monthly
//  questions + reset countdown — so free users can see the meter before it
//  bites; premium users see an Unlimited row in the same slot. These tests
//  pin the three card states (free / premium / not-loaded) and the countdown
//  wording, because the card is the only pre-paywall surface of the quota.
//

import Foundation
@testable import Hangs
import Testing
import ViewInspector

// MARK: - Helpers (duplicated per-suite convention, matches EntitlementReconcileTests)

/// Spin the main serial executor until `predicate` holds or the deadline
/// passes.
@MainActor
private func waitUntil(
    _ predicate: @MainActor () -> Bool,
    timeoutMillis: Int = 5000,
    _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMillis))
    while ContinuousClock.now < deadline {
        if predicate() { return }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
    if predicate() { return }
    Issue.record(comment ?? "waitUntil timed out after \(timeoutMillis)ms", sourceLocation: sourceLocation)
}

/// One-shot async gate: `wait()` suspends until `open()` is called. Lets a
/// test hold the mocked `/usage` fetch in flight deterministically, so the
/// loading-state assertion below isn't a wall-clock race.
private actor OneShotGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

@Suite("Home free-plan quota card (#87)")
@MainActor
struct HomeFreePlanCardTests {
    private func makeViewModel() -> QuizViewModel {
        QuizViewModel(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
    }

    private func usage(
        premium: Bool = false,
        remaining: Int? = 70,
        limit: Int? = 100,
        resetsIn: TimeInterval = 12 * 86400
    ) -> UsageInfo {
        UsageInfo(
            userId: "test-subject",
            isPremium: premium,
            questionsUsed: premium ? 0 : (limit ?? 0) - (remaining ?? 0),
            questionsLimit: premium ? nil : limit,
            remaining: premium ? nil : remaining,
            resetsAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(resetsIn)),
            subscriptionStatus: premium ? "active" : "none",
            creditBalance: 0
        )
    }

    @Test("Free user sees remaining count and reset countdown")
    func freeStateShowsCounterAndCountdown() async throws {
        let vm = makeViewModel()
        vm.usageInfo = usage()
        let view = HomeView(viewModel: vm)

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let count = try tree.find(viewWithAccessibilityIdentifier: "home.freePlanCount").text()
            #expect(try count.string() == "70 of 100 free questions left")

            let reset = try tree.find(viewWithAccessibilityIdentifier: "home.freePlanReset").text()
            #expect(try reset.string() == "resets in 12 days")

            // Premium row must not render for a free user.
            #expect(throws: (any Error).self) {
                try tree.find(viewWithAccessibilityIdentifier: "home.freePlanUnlimited")
            }
        }
    }

    @Test("Premium user sees Unlimited row, no counter, no countdown")
    func premiumStateShowsUnlimited() async throws {
        let vm = makeViewModel()
        vm.usageInfo = usage(premium: true)
        let view = HomeView(viewModel: vm)

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "home.freePlanUnlimited")
            }
            #expect(throws: (any Error).self) {
                try tree.find(viewWithAccessibilityIdentifier: "home.freePlanCount")
            }
            #expect(throws: (any Error).self) {
                try tree.find(viewWithAccessibilityIdentifier: "home.freePlanReset")
            }
        }
    }

    @Test("Usage still loading shows a loading placeholder, never a blank slot (#123)")
    func loadingUsageShowsPlaceholder() async throws {
        let mock = MockNetworkService()
        let gate = OneShotGate()
        // Holds the launch fetch in flight, deterministically, so the
        // assertion below observes .loading rather than racing a real fetch.
        mock.getUsageGate = { await gate.wait() }
        let vm = QuizViewModel(
            networkService: mock,
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )

        await waitUntil({ mock.getUsageCallCount >= 1 }, "launch usage fetch never started")
        #expect(vm.usageLoadState == .loading)
        #expect(vm.usageInfo == nil)

        let view = HomeView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            // This is the assertion that failed on pre-#123 code: the card
            // rendered EmptyView for the whole in-flight window instead of a
            // visible loading placeholder.
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "home.freePlanLoading")
            }
            // Neither the loaded card nor the failed-retry placeholder must
            // render while still loading — exactly one state at a time.
            #expect(throws: (any Error).self) {
                try tree.find(viewWithAccessibilityIdentifier: "home.freePlanCard")
            }
            #expect(throws: (any Error).self) {
                try tree.find(viewWithAccessibilityIdentifier: "home.freePlanRetryButton")
            }
        }

        await gate.open() // release the held fetch so the reconciler's task can finish cleanly
    }

    @Test("Usage that failed to load shows a retry placeholder instead of vanishing (#FIX2)")
    func failedUsageShowsRetryPlaceholder() async throws {
        let mock = MockNetworkService()
        mock.getUsageError = NetworkError.invalidResponse // every /usage attempt fails
        let vm = QuizViewModel(
            networkService: mock,
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )

        // The launch reconcile exhausts its bounded retries and marks the load
        // failed; the card must then render a retry affordance, not disappear.
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(15000))
        while ContinuousClock.now < deadline, vm.usageLoadState != .failed {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(vm.usageLoadState == .failed, "usage load never surfaced as failed")
        #expect(vm.usageInfo == nil)

        let view = HomeView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "home.freePlanRetryButton")
            }
            // The normal free-plan card must NOT render when there is no usage.
            #expect(throws: (any Error).self) {
                try tree.find(viewWithAccessibilityIdentifier: "home.freePlanCard")
            }
        }
    }

    // MARK: - Proactive paywall entry (#93 subscription IAP)
    // The card is the Home upgrade entry point: paywall was previously
    // reachable only via the 429 quota handlers.

    @Test("Free card shows Upgrade affordance; tap presents paywall and clears stale 429 error")
    func freeCardTapPresentsPaywall() async throws {
        let vm = makeViewModel()
        vm.usageInfo = usage()
        // Simulate a stale quota error from an earlier 429 — proactive entry
        // must clear it so PaywallView shows upgrade copy, not "limit reached".
        vm.quotaLimitError = QuotaLimitError(
            error: "Monthly limit reached",
            questionsUsed: 30,
            questionsLimit: 30,
            resetsAt: "2099-01-01T08:00:00.000Z",
            upgradeAvailable: true
        )
        let view = HomeView(viewModel: vm)

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "home.freePlanUpgrade")
            }
            try tree.find(viewWithAccessibilityIdentifier: "home.freePlanUpgradeButton")
                .button().tap()
            #expect(vm.showPaywall)
            #expect(vm.quotaLimitError == nil)
        }
    }

    @Test("Premium card is not tappable and shows no Upgrade affordance")
    func premiumCardHasNoUpgradeEntry() async throws {
        let vm = makeViewModel()
        vm.usageInfo = usage(premium: true)
        let view = HomeView(viewModel: vm)

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) {
                try tree.find(viewWithAccessibilityIdentifier: "home.freePlanUpgrade")
            }
            #expect(throws: (any Error).self) {
                try tree.find(viewWithAccessibilityIdentifier: "home.freePlanUpgradeButton")
            }
        }
    }

    // MARK: - Countdown wording (pure helpers)

    @Test("Countdown rounds up and never promises an early reset")
    func countdownWording() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func text(_ seconds: TimeInterval) -> String? {
            let info = UsageInfo(
                userId: "t", isPremium: false, questionsUsed: 0,
                questionsLimit: 100, remaining: 100,
                resetsAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(seconds)),
                subscriptionStatus: "none", creditBalance: 0
            )
            return HomeView.resetCountdown(info, now: now)
        }

        #expect(text(20 * 86400) == "resets in 20 days")
        #expect(text(86400) == "resets in 1 day")
        // 25h → "2 days", not "1 day": rounding up must not understate.
        #expect(text(25 * 3600) == "resets in 2 days")
        #expect(text(5 * 3600) == "resets in 5 hours")
        #expect(text(30 * 60) == "resets soon")
        #expect(text(-60) == "resets soon")
    }

    @Test("Track fraction follows remaining/limit and clamps")
    func quotaFraction() {
        #expect(HomeView.quotaFraction(usage(remaining: 70, limit: 100)) == 0.7)
        #expect(HomeView.quotaFraction(usage(remaining: 0, limit: 100)) == 0)
        #expect(HomeView.quotaFraction(usage(remaining: nil, limit: nil)) == 0)
    }
}
