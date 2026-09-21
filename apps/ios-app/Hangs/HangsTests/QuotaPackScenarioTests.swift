//
//  QuotaPackScenarioTests.swift
//  HangsTests
//
//  #180 track C — quota × pack cross-cutting scenarios, the iOS half. The
//  server owns the free monthly quota (its rollover is pinned in pytest,
//  `test_quota_pack_scenarios.py`); the app's job is to mirror it faithfully:
//
//  (b) a purchased pack keeps playing while the free quota is exhausted — the
//      pack start goes straight through while a free start on the same
//      account is still walled, with no purchase and no entitlement in between.
//  (c) the monthly reset is the server's UTC instant: the client parses it
//      with its offset, counts down to it, never resets the allowance on its
//      own when the local calendar month rolls over (Bratislava is already in
//      the next month at 23:xxZ on the last day), and picks the new allowance
//      up from the server mirror on foreground — no restart.
//
//  Scenario (a) — the wall hit MID-quiz, then a purchase, then the SAME quiz
//  continues — is a product change (today the wall ends the session on both
//  sides) and lands separately.
//
//  Harness mirrors `PurchaseEdgeCaseScenarioTests` (track B): `AppState`'s
//  wiring over the protocol mocks, driven on the injected clock, asserting
//  what the customer sees (quiz state, paywall, published usage mirror).
//

import Clocks
import Foundation
@testable import Hangs
import SwiftUI
import Testing

// MARK: - Helpers

/// The backend's wire shape for `resets_at`: Python `isoformat()` of an aware
/// UTC datetime — no fractional seconds, `+00:00` offset (never a `Z`).
private let novemberFirst = "2026-11-01T00:00:00+00:00"
private let novemberFirstInstant = Date(timeIntervalSince1970: 1_793_491_200) // 2026-11-01T00:00:00Z

private func makeUsage(remaining: Int, resetsAt: String = novemberFirst) -> UsageInfo {
    UsageInfo(
        userId: "mock-subject",
        isPremium: false,
        questionsUsed: 30 - remaining,
        questionsLimit: 30,
        remaining: remaining,
        resetsAt: resetsAt,
        subscriptionStatus: "none",
        creditBalance: 0
    )
}

private func makeQuotaLimitError() -> QuotaLimitError {
    QuotaLimitError(error: "quota_limit_reached", questionsUsed: 30, questionsLimit: 30, resetsAt: novemberFirst, upgradeAvailable: true)
}

@MainActor
private final class Loop {
    let vm: QuizViewModel
    let network: MockNetworkService
    let store: StoreManager

    /// Launches with `usage` as the server mirror and NO local entitlement
    /// (RC has nothing cached — the customer never subscribed).
    init(usage: UsageInfo, clock: TestClock<Duration> = TestClock()) async {
        network = Fixtures.makeFullMockNetwork()
        network.stubbedUsage = usage
        let purchases = MockPurchaseService()
        purchases.stubbedIsEntitled = false
        store = StoreManager(purchaseService: purchases)
        let store = store
        vm = QuizViewModel(
            networkService: network,
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            isLocallyEntitled: { store.isPurchased }, // AppState's wiring
            clock: AnyClock(clock)
        )
        store.onPurchaseSuccess = { [vm] in await vm.notifyPremiumPurchased() }
        await pumpUntil(
            { self.vm.usageInfo != nil && !self.vm.entitlementReconciler.isReconciling && self.store.offerings != nil },
            "launch never settled"
        )
    }

    /// The server walls free starts with the quota 429 — and, like the real
    /// `start_quiz`, lets a `pack_id` session through untouched.
    func wallFreeStarts() {
        network.createSessionError = NetworkError.quotaLimitReached(makeQuotaLimitError())
        network.createSessionErrorSparesPackSessions = true
    }

    /// A background → foreground round trip with `usage` as the server mirror —
    /// settled once the reconcile has PUBLISHED it.
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

// MARK: - (b) pack play while the free quota is exhausted

@MainActor
struct QuotaPackScenarioTests {
    @Test("(b) a purchased pack plays while the free quota is exhausted — no purchase, no entitlement, no paywall")
    func packPlaysBehindTheFreeWall() async {
        let loop = await Loop(usage: makeUsage(remaining: 0))
        #expect(loop.vm.usageInfo?.isLimitReached == true, "precondition: the free allowance is spent")
        loop.wallFreeStarts()

        // A free start is walled, exactly as before the pack was bought.
        await loop.vm.startNewQuiz()
        #expect(loop.vm.showPaywall == true, "a free start on an exhausted quota routes to the paywall")
        #expect(loop.vm.quizState == .idle)
        #expect(loop.network.capturedPackId == nil)

        // The customer closes the paywall and opens the pack they own instead.
        loop.vm.showPaywall = false
        await loop.vm.startNewQuiz(packId: "pack-owned-1")

        #expect(loop.vm.quizState == .askingQuestion, "the paid pack must play behind the free wall")
        #expect(loop.vm.currentQuestion != nil, "…with an actual question to answer")
        #expect(loop.network.capturedPackId == "pack-owned-1", "the pack start carries the pack id the server gates ownership on")
        #expect(loop.vm.showPaywall == false, "no paywall — the pack is not free content")
        #expect(loop.store.isPurchased == false, "no subscription was needed")
        #expect(loop.vm.usageInfo?.remaining == 0, "the free quota stays spent; the pack neither needs nor restores it")
    }

    // MARK: - (c) the monthly reset is the server's UTC instant

    @Test("(c) resets_at is parsed as the server's UTC instant in the backend wire format")
    func resetInstantParsesFromTheWireFormat() {
        #expect(makeUsage(remaining: 0).resetDate == novemberFirstInstant, "Python isoformat: no fractional seconds, +00:00 offset")
        #expect(
            makeUsage(remaining: 0, resetsAt: "2026-11-01T00:00:00.000Z").resetDate == novemberFirstInstant,
            "the fractional/Z spelling is the same instant"
        )
        #expect(
            makeUsage(remaining: 0, resetsAt: "2026-11-01T01:00:00+01:00").resetDate == novemberFirstInstant,
            "an offset is honoured, not stripped — 01:00 CET is midnight UTC"
        )
    }

    @Test("(c) the last hour of the month counts down to the UTC boundary even though the local calendar already says November")
    func countdownTrustsTheServerInstantNotTheLocalCalendar() {
        // 23:30Z on Oct 31 — Bratislava (CET after DST ended Oct 25) reads
        // Nov 1, 00:30. The allowance is NOT back yet: the server resets it
        // at 00:00Z, and the client must neither reset it locally nor count
        // down from a local midnight.
        let lastHalfHour = novemberFirstInstant.addingTimeInterval(-30 * 60)
        let usage = makeUsage(remaining: 0)
        #expect(usage.isLimitReached == true, "the client never resets the allowance on its own calendar")
        #expect(HomeView.resetCountdown(usage, now: lastHalfHour) == "resets soon")

        // Eleven hours out (14:00 CET) — hours, counted to the UTC instant.
        let elevenHoursOut = novemberFirstInstant.addingTimeInterval(-11 * 3600)
        #expect(HomeView.resetCountdown(usage, now: elevenHoursOut) == "resets in 11 hours")

        // A week out, across nothing but plain UTC seconds — the DST hour the
        // local week lost on Oct 25 cannot leak into the countdown.
        let weekOut = novemberFirstInstant.addingTimeInterval(-7 * 86400)
        #expect(HomeView.resetCountdown(usage, now: weekOut) == "resets in 7 days")
    }

    @Test("(c) the new month's allowance arrives from the server mirror on foreground — the quiz is playable again without a restart")
    func monthlyResetArrivesOnForeground() async {
        let loop = await Loop(usage: makeUsage(remaining: 0))
        loop.wallFreeStarts()
        await loop.vm.startNewQuiz()
        #expect(loop.vm.showPaywall == true, "precondition: walled on the last day of the month")
        loop.vm.showPaywall = false

        // Past 00:00Z the server sums no prior rows: a whole allowance, the
        // reset one month on, and free starts go through again.
        let decemberFirst = "2026-12-01T00:00:00+00:00"
        loop.network.createSessionError = nil
        await loop.foreground(expecting: makeUsage(remaining: 30, resetsAt: decemberFirst))

        #expect(loop.vm.usageInfo?.isLimitReached == false, "the published mirror carries the fresh allowance")
        #expect(loop.vm.usageInfo?.resetsAt == decemberFirst, "…and the next boundary")
        #expect(loop.store.isPurchased == false, "nothing was bought — this is the calendar, not a purchase")

        await loop.vm.startNewQuiz()
        #expect(loop.vm.quizState == .askingQuestion, "a free quiz is playable again with no restart")
        #expect(loop.vm.showPaywall == false, "the paywall must not re-present after the reset")
    }
}
