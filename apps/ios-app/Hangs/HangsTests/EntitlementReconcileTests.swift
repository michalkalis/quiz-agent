//
//  EntitlementReconcileTests.swift
//  HangsTests
//
//  #102 findings 1+2: entitlement re-sync only ever fired on identity-mint
//  events or post-purchase (and swallowed failure there) — a returning user
//  whose webhook landed while the app was closed, or whose sync failed
//  offline, never self-healed until their next purchase/sign-in. These tests
//  pin the new self-healing paths:
//    • launch fires exactly one entitlement sync attempt;
//    • background→foreground re-syncs AND refreshes usage (a webhook that
//      landed while backgrounded must not require a relaunch to show up);
//    • a sync failure retries with backoff instead of giving up immediately;
//    • launch + an immediate foreground never fire two concurrent syncs
//      (single-flight — the second caller joins the in-flight attempt);
//    • a 429 paywall gives RC's locally-entitled customer a bounded resync
//      window before showing, since the server usage mirror is the true gate.
//

import Foundation
import SwiftUI
import Testing
@testable import Hangs

// MARK: - Helpers

/// Spin the main serial executor until `predicate` holds or the deadline
/// passes. Mirrors `ScenePhaseTeardownTests.waitUntil` (duplicated locally,
/// matching this test target's existing per-suite convention).
@MainActor
private func waitUntil(
    _ predicate: @MainActor () -> Bool,
    timeoutMillis: Int = 5_000,
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

@MainActor
private func makeVM(
    network: MockNetworkService,
    isLocallyEntitled: @escaping @MainActor () -> Bool = { false }
) -> QuizViewModel {
    QuizViewModel(
        networkService: network,
        audioService: MockAudioService(),
        persistenceStore: MockPersistenceStore(),
        isLocallyEntitled: isLocallyEntitled
    )
}

private func makeUsage(remaining: Int, premium: Bool = false) -> UsageInfo {
    UsageInfo(
        userId: "mock-subject",
        isPremium: premium,
        questionsUsed: 100 - remaining,
        questionsLimit: 100,
        remaining: remaining,
        resetsAt: "",
        subscriptionStatus: premium ? "active" : "none",
        creditBalance: 0
    )
}

private func makeQuotaLimitError() -> QuotaLimitError {
    QuotaLimitError(error: "quota_exceeded", questionsUsed: 100, questionsLimit: 100, resetsAt: "", upgradeAvailable: true)
}

/// One-shot async gate: `wait()` suspends until `open()` is called. Lets a
/// test hold a mocked call in flight deterministically — no wall-clock race
/// against a fixed sleep duration, which flaked under full-suite parallel
/// contention (a real `Task.sleep`-based hold has no ordering guarantee
/// against other MainActor work queued at the same time).
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

@Suite("Entitlement re-sync on launch/foreground (#102)")
@MainActor
struct EntitlementReconcileTests {

    @Test("launch fires exactly one entitlement sync attempt")
    func launchSyncsOnce() async {
        let mock = Fixtures.makeFullMockNetwork()
        let vm = makeVM(network: mock)

        await waitUntil({ mock.syncEntitlementsCallCount == 1 }, "launch never triggered an entitlement sync")
        try? await Task.sleep(for: .milliseconds(50)) // let any stray extra call land before asserting exactly one
        #expect(mock.syncEntitlementsCallCount == 1, "launch must sync exactly once, not per observer/view")
        #expect(vm.quizState == .idle, "keep vm alive through the async waits above")
    }

    @Test("background → foreground re-syncs entitlements and refreshes usage")
    func foregroundReconciles() async {
        let mock = Fixtures.makeFullMockNetwork()
        let usageAtLaunch = makeUsage(remaining: 70)
        mock.stubbedUsage = usageAtLaunch
        let vm = makeVM(network: mock)

        await waitUntil({ vm.usageInfo == usageAtLaunch }, "launch reconcile never populated usage")
        let syncCountAfterLaunch = mock.syncEntitlementsCallCount

        // A webhook lands server-side while the app is backgrounded.
        let usageAfterForeground = makeUsage(remaining: 3, premium: true)
        mock.stubbedUsage = usageAfterForeground
        vm.handleScenePhase(.background)
        vm.handleScenePhase(.active)

        await waitUntil({ vm.usageInfo == usageAfterForeground }, "foreground never refreshed usage — stale quota would still show")
        #expect(mock.syncEntitlementsCallCount == syncCountAfterLaunch + 1, "foreground must fire its own entitlement sync")
    }

    @Test("a sync failure retries with backoff before giving up")
    func retriesWithBackoff() async {
        let mock = Fixtures.makeFullMockNetwork()
        mock.syncEntitlementsFailuresBeforeSuccess = 2 // fails twice, succeeds on the 3rd (bounded) attempt
        let vm = makeVM(network: mock)

        // Generous timeout: this is a real-time wait for the production
        // backoff sleeps (not a race), so it just needs enough headroom for
        // a loaded CI machine — not a tight bound.
        await waitUntil({ mock.syncEntitlementsCallCount == 3 }, timeoutMillis: 15_000, "retry loop gave up before its bounded 3rd attempt")
        await waitUntil({ vm.usageInfo != nil }, "usage never refreshed after the sync eventually recovered")
    }

    @Test("launch + an immediate foreground join one in-flight sync — no duplicate concurrent syncs")
    func dedupesConcurrentReconciles() async {
        let mock = Fixtures.makeFullMockNetwork()
        let gate = OneShotGate()
        mock.syncEntitlementsGate = { await gate.wait() } // holds the launch sync in flight, deterministically
        let vm = makeVM(network: mock)

        await waitUntil({ mock.syncEntitlementsCallCount == 1 }, "launch sync never started")
        // The launch sync is now provably suspended inside the gate — not a
        // timing guess. Fire a foreground reconcile while it's still in flight.
        vm.handleScenePhase(.active)

        // Give the foreground's reconcile Task a MainActor turn to run its
        // single-flight check (the launch sync itself cannot progress until
        // `gate.open()` below, so there is no race to win here).
        await Task.yield()
        await Task.yield()
        #expect(mock.syncEntitlementsCallCount == 1, "a foreground racing an in-flight sync must join it, not fire a second call")

        await gate.open()
        await waitUntil({ vm.usageInfo != nil }, "the joined reconcile never completed")
        #expect(mock.syncEntitlementsCallCount == 1, "still only one sync after both callers settle")
    }

    @Test("429 with RC locally entitled attempts a bounded re-sync before showing the paywall")
    func paywall429ResyncsWhenLocallyEntitled() async {
        let mock = Fixtures.makeFullMockNetwork()
        let vm = makeVM(network: mock, isLocallyEntitled: { true })

        await waitUntil({ vm.usageInfo != nil }, "launch reconcile never settled")
        let countBefore429 = mock.syncEntitlementsCallCount

        mock.createSessionError = NetworkError.quotaLimitReached(makeQuotaLimitError())
        await vm.startNewQuiz()

        #expect(vm.showPaywall == true)
        #expect(mock.syncEntitlementsCallCount == countBefore429 + 1, "RC-entitled locally → must attempt a resync before the paywall shows")
    }

    @Test("429 without local RC entitlement shows the paywall without attempting a resync")
    func paywall429SkipsResyncWhenNotEntitled() async {
        let mock = Fixtures.makeFullMockNetwork()
        let vm = makeVM(network: mock) // isLocallyEntitled defaults to { false }

        await waitUntil({ vm.usageInfo != nil }, "launch reconcile never settled")
        let countBefore429 = mock.syncEntitlementsCallCount

        mock.createSessionError = NetworkError.quotaLimitReached(makeQuotaLimitError())
        await vm.startNewQuiz()

        #expect(vm.showPaywall == true)
        #expect(mock.syncEntitlementsCallCount == countBefore429, "not locally entitled → no resync attempt, paywall shows immediately")
    }

    @Test("429 with RC locally entitled skips the paywall when the resync confirms entitlement")
    func paywall429SkippedWhenResyncConfirmsEntitlement() async {
        let mock = Fixtures.makeFullMockNetwork()
        let vm = makeVM(network: mock, isLocallyEntitled: { true })

        await waitUntil({ vm.usageInfo != nil }, "launch reconcile never settled")

        // The server mirror was lagging when the 429 hit, but the pre-paywall
        // resync (#102 review follow-up) lands successfully and the
        // subsequent usage refresh now shows the customer entitled.
        mock.stubbedUsage = makeUsage(remaining: 100, premium: true)
        mock.createSessionError = NetworkError.quotaLimitReached(makeQuotaLimitError())
        await vm.startNewQuiz()

        #expect(vm.showPaywall == false, "resync confirmed entitlement → must not strand a paying user behind the paywall")
        #expect(vm.quotaLimitError == nil, "no quota error should be surfaced once entitlement is confirmed")
        if case .error = vm.quizState {
            // Expected: a retryable error asking the user to try again, not the paywall.
        } else {
            Issue.record("expected an .error state prompting retry, got \(vm.quizState)")
        }
    }
}
