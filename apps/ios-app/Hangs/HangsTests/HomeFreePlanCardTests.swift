//
//  HomeFreePlanCardTests.swift
//  HangsTests
//
//  #87 (directive G2): Home shows the free-plan quota — remaining monthly
//  questions + reset countdown — so free users can see the meter before it
//  bites; Trubbo Plus subscribers see the plan name and what is left of the
//  month's 1,000 questions in the same slot (#199). These tests pin the three
//  card states (free / premium / not-loaded) and the countdown wording,
//  because the card is the only pre-paywall surface of the quota.
//

import Clocks
import Foundation
@testable import Hangs
import Testing
import ViewInspector

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
    /// Every production wait runs on the injected clock (#180 track A); a
    /// parked `TestClock` means nothing on the quiz path can pass time behind
    /// these card assertions unless a test drives it.
    private func makeViewModel() -> QuizViewModel {
        QuizViewModel(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService(),
            clock: AnyClock(TestClock())
        )
    }

    /// A subscriber defaults to Trubbo Plus's real shape (870 of 1,000 left);
    /// a free user to 70 of 100.
    private func usage(
        premium: Bool = false,
        remaining: Int? = nil,
        limit: Int? = nil,
        resetsIn: TimeInterval = 12 * 86400,
        credits: Int = 0,
        status: String? = nil
    ) -> UsageInfo {
        let remaining = remaining ?? (premium ? 870 : 70)
        let limit = limit ?? (premium ? 1000 : 100)
        return UsageInfo(
            userId: "test-subject",
            isPremium: premium,
            questionsUsed: limit - remaining,
            questionsLimit: limit,
            remaining: remaining,
            resetsAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(resetsIn)),
            subscriptionStatus: status ?? (premium ? "active" : "none"),
            creditBalance: credits
        )
    }

    @Test("Free user sees the remaining count as the Anton headline + reset countdown (#123 Variant A)")
    func freeStateShowsCounterAndCountdown() async throws {
        let vm = makeViewModel()
        vm.usageInfo = usage()
        let view = HomeView(viewModel: vm)

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            // The remaining count is now the dominant Anton number (verbatim),
            // with "of N free questions left" as a muted caption beside it.
            let primary = try tree.find(viewWithAccessibilityIdentifier: "home.planPrimary").text()
            #expect(try primary.string() == "70")
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "home.planCaption")
            }

            let reset = try tree.find(viewWithAccessibilityIdentifier: "home.freePlanReset").text()
            #expect(try reset.string() == "resets in 12 days")

            // A plain free user (no credits) gets no two-currency legend and no
            // plan name.
            #expect(throws: (any Error).self) {
                try tree.find(viewWithAccessibilityIdentifier: "home.planLegend")
            }
            #expect(throws: (any Error).self) {
                try tree.find(viewWithAccessibilityIdentifier: "home.planName")
            }
        }
    }

    @Test("Subscriber sees the Trubbo Plus name, active pill and what is left of the month's 1,000 questions (#199)")
    func premiumStateShowsPlanAndAllowance() async throws {
        let vm = makeViewModel()
        vm.usageInfo = usage(premium: true)
        let view = HomeView(viewModel: vm)

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let name = try tree.find(viewWithAccessibilityIdentifier: "home.planName").text()
            #expect(try name.string() == "Trubbo Plus")
            // "active" status pill and the remaining-allowance meta line.
            let pill = try tree.find(viewWithAccessibilityIdentifier: "home.planStatusPill").text()
            #expect(try pill.string() == "active")
            // The identifier sits on the Group around the meta, so reach its Text.
            let meta = try tree.find(viewWithAccessibilityIdentifier: "home.planMeta").find(ViewType.Text.self)
            #expect(try meta.string(locale: Locale(identifier: "en")) == "870 of 1,000 left · resets in 12 days")
            #expect(try meta.string(locale: Locale(identifier: "sk")) == "Ešte 870 z 1\u{00A0}000 · resets in 12 days",
                    "sk/cs thousands carry a non-breaking space")
            // The plan name carries the card, so no numeric headline and no
            // free-reset line.
            #expect(throws: (any Error).self) {
                try tree.find(viewWithAccessibilityIdentifier: "home.planPrimary")
            }
            #expect(throws: (any Error).self) {
                try tree.find(viewWithAccessibilityIdentifier: "home.freePlanReset")
            }
            // No pack-credit chip when the subscriber holds no credits.
            #expect(throws: (any Error).self) {
                try tree.find(viewWithAccessibilityIdentifier: "home.planCreditChip")
            }
        }
    }

    @Test("Subscriber payload without a limit (older backend) still reads as an active subscription, never a made-up count")
    func subscriberWithoutLimitFallsBackToStatus() async throws {
        let vm = makeViewModel()
        vm.usageInfo = UsageInfo(
            userId: "test-subject", isPremium: true, questionsUsed: 0,
            questionsLimit: nil, remaining: nil,
            resetsAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(12 * 86400)),
            subscriptionStatus: "active", creditBalance: 0
        )
        let view = HomeView(viewModel: vm)

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let meta = try tree.find(viewWithAccessibilityIdentifier: "home.planMeta").find(ViewType.Text.self)
            #expect(try meta.string() == "Subscription active")
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
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService(),
            clock: AnyClock(TestClock())
        )

        await pumpUntil({ mock.getUsageCallCount >= 1 }, "launch usage fetch never started")
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
            // #123 Track B: the loading card holds the loaded card's full
            // scaffold — the "your plan" label row and a skeleton meta line —
            // so the slot doesn't jump when /usage resolves. A single-row
            // spinner (the pre-Track-B shape) would fail this.
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "home.planLabel")
            }
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "home.planLoadingSkeleton")
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
        // Drive the bounded retry's backoff instead of waiting it out in real
        // time (#133 audit, #180 track A): the fetch retries on THIS clock.
        let clock = TestClock()
        let vm = QuizViewModel(
            networkService: mock,
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService(),
            clock: AnyClock(clock)
        )

        // The launch reconcile exhausts its bounded retries — released one by
        // one across the shipped 0.2 s / 0.4 s backoffs — and marks the load
        // failed; the card must then render a retry affordance, not disappear.
        await pumpUntil({ mock.getUsageCallCount == 1 }, "the launch usage fetch never started")
        await clock.advance(by: .milliseconds(201))
        await pumpUntil({ mock.getUsageCallCount == 2 }, "the 2nd attempt never fired once its backoff elapsed")
        await clock.advance(by: .milliseconds(401))
        await pumpUntil({ vm.usageLoadState == .failed }, "usage load never surfaced as failed")
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

    @Test("Subscriber card taps through to Manage, not the paywall (#123 Variant A)")
    func premiumCardShowsManageEntry() async throws {
        let vm = makeViewModel()
        vm.usageInfo = usage(premium: true)
        let view = HomeView(viewModel: vm)

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            // The whole card is now the manage-subscription tap target — not the
            // free-family paywall button, and not the free "Upgrade" link.
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "home.planManageButton")
            }
            let cta = try tree.find(viewWithAccessibilityIdentifier: "home.planManageCTA").text()
            #expect(try cta.string() == "Manage")
            #expect(throws: (any Error).self) {
                try tree.find(viewWithAccessibilityIdentifier: "home.freePlanUpgradeButton")
            }
            #expect(throws: (any Error).self) {
                try tree.find(viewWithAccessibilityIdentifier: "home.freePlanUpgrade")
            }
        }
    }

    // MARK: - #123 Track B entitlement states

    @Test("Free + pack credits: headline is the combined total; legend names both currencies")
    func freeWithCreditsShowsCombinedTotalAndLegend() async throws {
        let vm = makeViewModel()
        // 12 monthly free + 100 pack credits must read as one spendable "112".
        vm.usageInfo = usage(remaining: 12, limit: 30, credits: 100)
        let view = HomeView(viewModel: vm)

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let primary = try tree.find(viewWithAccessibilityIdentifier: "home.planPrimary").text()
            #expect(try primary.string() == "112")
            let caption = try tree.find(viewWithAccessibilityIdentifier: "home.planCaption").text()
            #expect(try caption.string() == "questions available")
            // Both balances > 0 → the two-currency legend renders, and the link
            // verb becomes "More" (not "Upgrade").
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "home.planLegend")
            }
            let link = try tree.find(viewWithAccessibilityIdentifier: "home.freePlanUpgrade").text()
            #expect(try link.string() == "More")
            // Free + credits still routes to the paywall (family A), not manage.
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "home.freePlanUpgradeButton")
            }
        }
    }

    @Test("Free + credits but zero monthly free left: no legend (only one balance > 0)")
    func freeWithZeroMonthlyHidesLegend() async throws {
        let vm = makeViewModel()
        vm.usageInfo = usage(remaining: 0, limit: 30, credits: 50)
        let view = HomeView(viewModel: vm)

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            // Combined total is just the credits; the legend row is a two-way
            // split, so it stays hidden unless BOTH balances are non-zero.
            let primary = try tree.find(viewWithAccessibilityIdentifier: "home.planPrimary").text()
            #expect(try primary.string() == "50")
            #expect(throws: (any Error).self) {
                try tree.find(viewWithAccessibilityIdentifier: "home.planLegend")
            }
        }
    }

    @Test("Subscriber + credits: Trubbo Plus plus a purple credit chip, credits stated not counted")
    func subscriberWithCreditsShowsCreditChip() async throws {
        let vm = makeViewModel()
        vm.usageInfo = usage(premium: true, credits: 100)
        let view = HomeView(viewModel: vm)

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "home.planName")
            }
            // The credits a subscriber holds are kept for later, not spent down
            // before the plan's monthly allowance — surfaced as a chip, not the headline.
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "home.planCreditChip")
            }
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "home.planManageButton")
            }
        }
    }

    @Test("Grace (renewal failed): amber pill + Fix payment link, still the manage surface")
    func graceShowsRenewalFailedAndFixPayment() async throws {
        let vm = makeViewModel()
        // A grace-period subscriber can still read isPremium == true — the
        // status field, not isPremium, must drive the grace visual.
        vm.usageInfo = usage(premium: true, status: "grace")
        let view = HomeView(viewModel: vm)

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let pill = try tree.find(viewWithAccessibilityIdentifier: "home.planStatusPill").text()
            #expect(try pill.string() == "renewal failed")
            let cta = try tree.find(viewWithAccessibilityIdentifier: "home.planManageCTA").text()
            #expect(try cta.string() == "Fix payment")
            // A lapsing subscriber is the one person who must act — Home warns,
            // and the whole card routes to the billing/manage surface.
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "home.planManageButton")
            }
        }
    }

    @Test("Expired: collapses to the free layout with an 'ended' pill + Resubscribe → paywall")
    func expiredCollapsesToFreeWithEndedPill() async throws {
        let vm = makeViewModel()
        // Expired has already dropped back to the free tier server-side, so the
        // free quota fields are populated again.
        vm.usageInfo = usage(remaining: 30, limit: 30, status: "expired")
        let view = HomeView(viewModel: vm)

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let primary = try tree.find(viewWithAccessibilityIdentifier: "home.planPrimary").text()
            #expect(try primary.string() == "30")
            let pill = try tree.find(viewWithAccessibilityIdentifier: "home.planStatusPill").text()
            #expect(try pill.string() == "ended")
            let link = try tree.find(viewWithAccessibilityIdentifier: "home.freePlanUpgrade").text()
            #expect(try link.string() == "Resubscribe")
            // Expired routes to the paywall (resubscribe), not the manage surface.
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "home.freePlanUpgradeButton")
            }
        }
    }

    // MARK: - State derivation (pure helper — the six-visual contract)

    @Test("state(for:) maps subscriptionStatus + credits onto the six card visuals")
    func planStateDerivation() {
        // status is authoritative for grace/expired even when isPremium is set.
        #expect(HomePlanCard.state(for: usage()) == .free)
        #expect(HomePlanCard.state(for: usage(credits: 100)) == .freeWithCredits)
        #expect(HomePlanCard.state(for: usage(premium: true)) == .subscriber)
        #expect(HomePlanCard.state(for: usage(premium: true, credits: 100)) == .subscriberWithCredits)
        #expect(HomePlanCard.state(for: usage(premium: true, status: "grace")) == .grace)
        #expect(HomePlanCard.state(for: usage(remaining: 30, limit: 30, status: "expired")) == .expired)
        // grace/expired win over a stale isPremium flag.
        #expect(HomePlanCard.state(for: usage(premium: true, status: "expired")) == .expired)
    }

    @Test("combinedTotal sums monthly free remaining + pack credits")
    func combinedTotalMath() {
        #expect(HomePlanCard.combinedTotal(usage(remaining: 12, limit: 30, credits: 100)) == 112)
        #expect(HomePlanCard.combinedTotal(usage(remaining: 0, limit: 30, credits: 50)) == 50)
        #expect(HomePlanCard.combinedTotal(usage(remaining: 30, limit: 30, credits: 0)) == 30)
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

    // WHY (#199): a Trubbo Plus subscriber now has a real monthly limit, so
    // spending it must read as "limit reached" like the free tier does; a
    // payload without a limit (older backend) never claims a limit was hit.
    @Test("A subscriber who spent the month's allowance has reached the limit; one with no limit data has not")
    func subscriberLimitReached() {
        #expect(usage(premium: true, remaining: 0, limit: 1000).isLimitReached)
        #expect(!usage(premium: true, remaining: 870, limit: 1000).isLimitReached)
        let noLimit = UsageInfo(
            userId: "t", isPremium: true, questionsUsed: 0, questionsLimit: nil, remaining: nil,
            resetsAt: "", subscriptionStatus: "active", creditBalance: 0
        )
        #expect(!noLimit.isLimitReached)
    }

    // WHY (#199 review): the server never sets the legacy `is_premium` flag for
    // a real subscriber, it reports Plus through the subscription status. Reading
    // the flag alone told a paying subscriber they were on the free plan and
    // offered them their own subscription again.
    @Test("Trubbo Plus is read from the subscription status (active or grace), not the legacy premium flag")
    func plusFollowsSubscriptionStatus() {
        func payload(_ status: String) -> UsageInfo {
            UsageInfo(
                userId: "t", isPremium: false, questionsUsed: 130, questionsLimit: 1000, remaining: 870,
                resetsAt: "", subscriptionStatus: status, creditBalance: 0
            )
        }
        #expect(payload("active").isPlus)
        #expect(payload("grace").isPlus)
        #expect(!payload("expired").isPlus)
        #expect(!payload("none").isPlus)
    }

    @Test("Track fraction follows remaining/limit and clamps")
    func quotaFraction() {
        #expect(HomeView.quotaFraction(usage(remaining: 70, limit: 100)) == 0.7)
        #expect(HomeView.quotaFraction(usage(remaining: 0, limit: 100)) == 0)
        #expect(HomeView.quotaFraction(usage(premium: true, remaining: 870, limit: 1000)) == 0.87)
        let noLimit = UsageInfo(
            userId: "t", isPremium: false, questionsUsed: 0,
            questionsLimit: nil, remaining: nil,
            resetsAt: "", subscriptionStatus: "none", creditBalance: 0
        )
        #expect(HomeView.quotaFraction(noLimit) == 0)
    }
}
