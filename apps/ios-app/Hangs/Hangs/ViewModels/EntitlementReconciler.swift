//
//  EntitlementReconciler.swift
//  Hangs
//
//  Entitlement/usage/paywall slice extracted from QuizViewModel (#113 T1).
//

import Combine
import Foundation
import os

/// Owns the paywall/quota/usage state and the server entitlement re-sync
/// flows (#102 findings 1+2): the launch/foreground reconcile (single-flight,
/// bounded backoff), the post-purchase sync, and the bounded pre-paywall
/// resync window for a 429 that hits a locally-entitled customer. The
/// QuizViewModel façade owns this object, re-publishes its changes, and
/// re-exposes the slice via forwarding accessors, so views and tests keep
/// binding QuizViewModel (#113 decision 2). The server remains the sole
/// source of truth for entitlement — nothing here grants client-side.
@MainActor
final class EntitlementReconciler: ObservableObject {
    /// Whether the `/usage` mirror has ever loaded, so the Home card can tell
    /// "still loading" apart from "the fetch failed" and stop silently
    /// vanishing on a transient failure (typically a Fly cold start) — #FIX2.
    /// `usageInfo` alone can't express this: it is `nil` in both cases.
    enum UsageLoadState {
        /// No successful load yet — the launch/foreground fetch is still in
        /// flight or awaiting its first attempt. The card shows nothing.
        case loading
        /// `usageInfo` reflects a successful `/usage` fetch.
        case loaded
        /// Every bounded attempt failed and `usageInfo` is still `nil` — the
        /// card shows a lightweight retry placeholder instead of disappearing.
        case failed
    }

    // Paywall state
    @Published var showPaywall: Bool = false
    @Published var quotaLimitError: QuotaLimitError?
    @Published var usageInfo: UsageInfo?
    /// Load status of the `/usage` mirror (see `UsageLoadState`). Only flips to
    /// `.failed` when a fetch exhausts its retries with no cached `usageInfo`;
    /// a failed *refresh* over an already-loaded value keeps the stale card
    /// rather than blanking it.
    @Published private(set) var usageLoadState: UsageLoadState = .loading

    private let networkService: NetworkServiceProtocol

    /// Reads RevenueCat's local cache for whether the customer holds the
    /// `unlimited` entitlement — used ONLY to decide whether a 429 paywall
    /// should first give the server mirror a short chance to catch up
    /// (`resyncBeforePaywallIfLocallyEntitled`, #102 finding 1). The server
    /// `/usage` gate remains the sole source of truth for whether the user is
    /// actually unlimited; this never grants anything client-side. Defaults
    /// to "not entitled" so existing call sites/tests are unaffected unless
    /// `AppState` wires the real RC-backed check.
    private let isLocallyEntitled: @MainActor () -> Bool

    /// Single in-flight entitlement re-sync — a launch and an immediate scene
    /// `.active` (or two rapid foregrounds) join the same attempt instead of
    /// firing duplicate network calls (mirrors AuthService's single-flight
    /// refresh). Set/cleared by `reconcileEntitlements()` only, cancelled in
    /// `deinit` (#102 findings 1+2).
    private var reconcileTask: Task<Void, Never>?

    /// Single in-flight `/usage` fetch — the launch reconcile and
    /// `HomeView.onAppear` both call `refreshUsage()` at startup, so they join
    /// one attempt instead of firing duplicate `/usage` calls (#FIX2). Set/
    /// cleared by `refreshUsage()` only, cancelled in `deinit`.
    private var usageFetchTask: Task<Void, Never>?

    init(
        networkService: NetworkServiceProtocol,
        isLocallyEntitled: @escaping @MainActor () -> Bool
    ) {
        self.networkService = networkService
        self.isLocallyEntitled = isLocallyEntitled

        // Entitlement re-sync on launch (#102 finding 1): the identity-mint
        // bridge (AppState.setAccountLinkedHandler) only fires on anon-
        // bootstrap/sign-in/refresh-remint, not a normal launch with an
        // already-valid token — a returning user whose webhook landed while
        // the app was closed otherwise never reconciles until their next
        // purchase. `reconcileEntitlements()` is single-flight and retries
        // with backoff; failure is logged only (server stays source of truth).
        Task { [weak self] in
            await self?.reconcileEntitlements()
        }
    }

    deinit {
        reconcileTask?.cancel()
        usageFetchTask?.cancel()
    }

    /// Clears the paywall/quota UI state (#113 T7 unified reset model — the
    /// façade's `resetState`/`transition` invokes this once T7 wires the
    /// per-child `reset()` calls). `usageInfo` deliberately survives: it is a
    /// server mirror, not phase-scoped UI state.
    func reset() {
        showPaywall = false
        quotaLimitError = nil
    }

    /// Proactive paywall entry (#93 subscription IAP — paywall was reachable
    /// only via the 429 quota handlers). Called from the Home free-plan card
    /// and the Settings subscription row. Clears any stale quota error first
    /// so PaywallView shows the upgrade pitch, not leftover "limit reached" copy.
    func presentPaywall() {
        quotaLimitError = nil
        showPaywall = true
    }

    /// Surface the paywall for a 429 quota block, carrying the quota error so
    /// PaywallView shows "limit reached" copy instead of the generic upgrade
    /// pitch (contrast `presentPaywall()`). Called by the façade's
    /// `handleError` after `resyncBeforePaywallIfLocallyEntitled` failed to
    /// confirm an entitlement.
    func presentQuotaPaywall(_ limitError: QuotaLimitError) {
        quotaLimitError = limitError
        showPaywall = true
    }

    /// Fetch current usage info from backend (for displaying remaining
    /// questions). Identity is the bearer subject, derived server-side —
    /// the same account purchases land on (#96 P1).
    ///
    /// Single-flight (a launch reconcile and `HomeView.onAppear` fire this
    /// concurrently at startup — they join one fetch) and bounded-retry: a
    /// single transient failure (a Fly cold start exceeding the 10s `/usage`
    /// timeout) must not silently strand the Home quota card with no data and
    /// nothing to reload it (#FIX2). Failure after the final attempt is logged
    /// only and, if nothing was ever loaded, flips `usageLoadState` to
    /// `.failed` so the card shows a retry affordance instead of vanishing.
    func refreshUsage() async {
        if let usageFetchTask {
            await usageFetchTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performUsageRefresh()
        }
        usageFetchTask = task
        await task.value
        usageFetchTask = nil
    }

    /// Bounded exponential-backoff `/usage` fetch (3 attempts) — mirrors the
    /// shape of `syncEntitlementsWithRetry`. On success publishes the mirror
    /// and marks `.loaded`; on final failure keeps any already-loaded
    /// `usageInfo` (a stale card beats a blank one) and only marks `.failed`
    /// when there is nothing to show.
    private func performUsageRefresh(maxAttempts: Int = 3) async {
        for attempt in 1 ... maxAttempts {
            guard !Task.isCancelled else { return }
            do {
                usageInfo = try await networkService.getUsage()
                usageLoadState = .loaded
                return
            } catch {
                guard attempt < maxAttempts else {
                    Logger.network.warning("⚠️ Failed to fetch usage info after \(attempt) attempts: \(error, privacy: .public)")
                    if usageInfo == nil { usageLoadState = .failed }
                    return
                }
                let backoffSeconds = 0.2 * pow(2.0, Double(attempt - 1))
                try? await Task.sleep(for: .seconds(backoffSeconds))
            }
        }
    }

    /// Refresh usage after a purchase or restore (subscription or pack).
    /// Entitlement is granted server-side via RC webhooks (#93) — the client
    /// never self-grants (the old `setPremium` call sent no admin key and
    /// always 401'd, #60). RC webhooks land seconds-to-minutes after purchase,
    /// so sync via the purchase→webhook propagation bridge
    /// (`POST /entitlements/sync`, bounded retry+backoff — same helper the
    /// launch/foreground reconcile uses, #102 finding 1) BEFORE re-fetching
    /// `/usage` — otherwise a just-paid user can still hit the 429 gate until
    /// the mirror catches up. A short bounded re-check here (not a new polling
    /// loop) gives `StoreManager.purchase()` a real chance to land on
    /// `.success` instead of the transient `.activating` state (#102 finding
    /// 4) before the caller has to fall back to later convergence points.
    ///
    /// Returns whether the refreshed usage shows an active entitlement
    /// (premium OR a non-zero pack credit balance) — `StoreManager.
    /// restorePurchases()` uses this to detect a pack-only recovery, since
    /// `isPurchased` never reflects consumable packs (#102 finding 3); `.purchase()`
    /// uses it to decide between `.success` and `.activating` (#102 finding 4).
    @discardableResult
    func notifyPremiumPurchased() async -> Bool {
        await syncEntitlementsWithRetry()
        await refreshUsage()
        return (usageInfo?.isPremium ?? false) || (usageInfo?.creditBalance ?? 0) > 0
    }

    /// Re-syncs entitlements (bounded retry+backoff) then refreshes usage —
    /// single-flight so a launch and scene `.active` (or two rapid
    /// foregrounds) collapse onto one attempt rather than firing duplicate
    /// network calls. Called from `init` (launch) and the façade's
    /// `handleScenePhase(.active)` (foreground) — #102 findings 1+2. The
    /// server remains the sole source of truth; this only asks it to catch up
    /// sooner than the next purchase/sign-in event would.
    func reconcileEntitlements() async {
        if let reconcileTask {
            await reconcileTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.syncEntitlementsWithRetry()
            await self.refreshUsage()
        }
        reconcileTask = task
        await task.value
        reconcileTask = nil
    }

    /// Bounded exponential-backoff retry for the entitlement sync (3
    /// attempts) — a single missed sync (offline in a tunnel, RC webhook lag)
    /// must not strand a paying user behind the paywall until their next
    /// purchase/sign-in event. Failure after the final attempt is logged only
    /// (Sentry breadcrumb via `SentryLog`) — the webhook still lands on its
    /// own; the client never grants anything itself.
    private func syncEntitlementsWithRetry(maxAttempts: Int = 3) async {
        for attempt in 1 ... maxAttempts {
            guard !Task.isCancelled else { return }
            do {
                try await networkService.syncEntitlements()
                return
            } catch {
                guard attempt < maxAttempts else {
                    SentryLog.warn(
                        "entitlements/sync failed after \(attempt) attempts (webhook will still catch up)",
                        category: .network,
                        attributes: ["error": String(describing: error)]
                    )
                    return
                }
                let backoffSeconds = 0.2 * pow(2.0, Double(attempt - 1))
                try? await Task.sleep(for: .seconds(backoffSeconds))
            }
        }
    }

    /// Bounded pre-paywall reconciliation (#102 finding 1): if RC's local
    /// cache already reports the customer entitled, the 429 just hit is
    /// almost certainly the server mirror lagging behind a purchase/restore
    /// whose sync failed or whose webhook hasn't landed yet — give it a
    /// short, single-attempt window before the paywall renders, instead of
    /// making the UI hang for the full launch/foreground retry loop. If it
    /// doesn't land in time, show the paywall anyway — the next
    /// launch/foreground reconcile (or the webhook) will still catch it up.
    ///
    /// Returns whether the just-refreshed usage now confirms an active
    /// entitlement (premium OR a non-zero pack credit) — callers use this to
    /// skip presenting the paywall for the cycle that just resynced, instead
    /// of showing it unconditionally regardless of outcome (#102 review
    /// follow-up).
    @discardableResult
    func resyncBeforePaywallIfLocallyEntitled() async -> Bool {
        guard isLocallyEntitled() else { return false }
        let networkService = self.networkService
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await networkService.syncEntitlements() }
            group.addTask { try? await Task.sleep(for: .seconds(2)) }
            await group.next()
            group.cancelAll()
        }
        await refreshUsage()
        return (usageInfo?.isPremium ?? false) || (usageInfo?.creditBalance ?? 0) > 0
    }
}
