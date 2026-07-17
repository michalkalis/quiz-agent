//
//  StoreManager.swift
//  Hangs
//
//  RevenueCat integration for freemium paywall (issue #93).
//  Offerings = one auto-renewing subscription (monthly + annual, entitlement
//  "unlimited") + one consumable question pack. RC owns receipt validation +
//  subscription lifecycle; the backend owns the credit ledger + quota gate —
//  entitlement is never client-trusted (see D-RC in issue-93).
//
//  StoreManager is the orchestrator: it manages @Published state and
//  coordinates calls through an injected PurchaseService protocol.
//  LivePurchaseService (default) delegates to the real RevenueCat SDK.
//  MockPurchaseService enables daemon-free unit tests.
//

import Combine
import Foundation
import os

/// Pinned RC / App Store identifiers (issue #93 D-ids). Seed migration `0005`
/// and the RC offering both hardcode these exact strings.
enum StoreProduct {
    /// Subscription product ids (RC's built-in `.monthly`/`.annual` offering
    /// accessors resolve these by billing period, not by this string).
    static let monthlySubId = "com.carquiz.unlimited.monthly"
    static let annualSubId = "com.carquiz.unlimited.annual"
    /// Consumable pack (+100 questions, never expires).
    static let packId = "com.carquiz.pack.questions100"
    /// The RC *package* identifier in the `default` offering for the pack
    /// (subs are looked up via `.monthly`/`.annual`, the pack needs its
    /// custom package identifier — issue #93 Session 0 provisioning).
    static let packPackageIdentifier = "pack_questions_100"
    /// RC entitlement id granting unlimited questions.
    static let entitlementId = "unlimited"

    /// Retired non-consumable from the pre-#93 StoreKit-only stack — kept as
    /// a comment for historical reference only, never referenced in code.
    /// static let unlimited = "com.carquiz.unlimited"
}

/// The lifecycle of the most recent purchase/restore attempt, published so the
/// paywall can render every outcome — silent success/failure was the founder's
/// "no response" re-prompt loop (#96 P1).
enum PurchaseState: Equatable {
    case idle
    case purchasing(productID: String)
    /// `productID` is nil for a restore (the restored product isn't known).
    case success(productID: String?)
    /// RC confirmed the purchase (receipt is real, `checkPurchaseStatus()` ran)
    /// but the post-purchase reconciliation bridge did not observe the server
    /// `/usage` mirror confirming premium/credits within its bounded retry —
    /// the money moved but the server gate may still deny a quiz start for a
    /// few more seconds. Distinct from `.success` so the paywall shows a
    /// "finishing activation" presentation instead of claiming the entitlement
    /// is fully live (issue #102 finding 4). Resolves on its own via the next
    /// launch/foreground reconcile or the pre-paywall resync — no polling here.
    case activating(productID: String?)
    case cancelled
    case pending
    /// Restore completed but no active entitlement was found — informational,
    /// not a failure, but it must still be visible (#96 P1: no silent ends).
    case nothingToRestore
    case failed(message: String)
}

/// Manages in-app purchases via RevenueCat
@MainActor
final class StoreManager: ObservableObject {
    @Published private(set) var offerings: PurchasableOfferings?
    /// True when the customer holds an active `unlimited` entitlement
    /// (subscription only — pack purchases never set this).
    @Published private(set) var isPurchased: Bool = false
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var hasAttemptedOfferingsLoad: Bool = false
    @Published var purchaseError: String?
    /// Outcome of the in-flight/last purchase attempt. The paywall renders
    /// this exhaustively; post-purchase side effects hang off it too (they
    /// used to hang off the `isPurchased` *state*, which a consumable pack
    /// by design never flips — the P1 dead end).
    @Published private(set) var purchaseState: PurchaseState = .idle

    /// Post-purchase continuation — set once by AppState. Runs after ANY
    /// successful purchase or restore attempt: `POST /entitlements/sync` +
    /// `/usage` refresh, so the server mirror and the visible quota react
    /// without waiting for the RC webhook. Returns whether the server mirror
    /// now shows an active entitlement (subscription OR pack credits) —
    /// `restorePurchases()` uses this to detect a pack-only recovery, since
    /// consumable packs never flip `isPurchased` (issue #102 finding 3).
    var onPurchaseSuccess: (@MainActor () async -> Bool)?

    private let purchaseService: PurchaseService
    private var transactionListener: Task<Void, Never>?

    /// Default initializer — uses LivePurchaseService backed by the real RC SDK.
    /// Preserves callsite compatibility: `StoreManager()` continues to work.
    init() {
        purchaseService = LivePurchaseService()
        transactionListener = nil
        transactionListener = listenForEntitlementUpdates()
        Task { await loadOfferings() }
        Task { await checkPurchaseStatus() }
    }

    /// Testable initializer — injects a PurchaseService (e.g. MockPurchaseService).
    init(purchaseService: PurchaseService) {
        self.purchaseService = purchaseService
        transactionListener = nil
        transactionListener = listenForEntitlementUpdates()
        Task { await loadOfferings() }
        Task { await checkPurchaseStatus() }
    }

    deinit {
        transactionListener?.cancel()
    }

    // MARK: - Offerings Loading

    func loadOfferings() async {
        offerings = await purchaseService.loadOfferings()
        hasAttemptedOfferingsLoad = true
        if offerings == nil {
            Logger.quiz.error("❌ StoreManager: Offerings not found or unavailable")
        }
    }

    // MARK: - Purchase

    /// Purchases a package by product id — either subscription (monthly/annual)
    /// or the consumable pack. Only a subscription purchase flips `isPurchased`.
    func purchase(productID: String) async {
        isLoading = true
        purchaseError = nil
        purchaseState = .purchasing(productID: productID)
        SentryLog.info("purchase started", category: .quiz, attributes: ["product": productID])

        do {
            let outcome = try await purchaseService.purchase(productID: productID)

            switch outcome {
            case .success(let unlimitedActive):
                let isSubscription = productID == StoreProduct.monthlySubId
                    || productID == StoreProduct.annualSubId
                if isSubscription && !unlimitedActive {
                    // The store sheet completed but the entitlement did NOT
                    // activate (RC product↔entitlement mapping or store-side
                    // failure). Silent success here was the founder's
                    // re-prompt loop — fail loud instead (#96 P1).
                    let message = String(localized: "The purchase went through but didn't activate. Try Restore purchases — if that doesn't help, contact support.", comment: "Paywall error when a subscription purchase completes without activating the entitlement")
                    purchaseError = message
                    purchaseState = .failed(message: message)
                    SentryLog.error("purchase success without entitlement", category: .quiz, attributes: ["product": productID])
                } else {
                    Logger.quiz.info("✅ StoreManager: Purchase successful")
                    SentryLog.info("purchase success", category: .quiz, attributes: ["product": productID])
                    // Re-derive from the SDK rather than assuming — a pack purchase
                    // must not flip isPurchased, and this also catches an already-
                    // entitled subscriber buying the other billing period.
                    await checkPurchaseStatus()
                    // The bridge (bounded sync retry + usage refresh) is the only
                    // signal that reflects the SERVER gate — RC's receipt alone
                    // (checkPurchaseStatus above) is not enough to call this
                    // "success" (#102 finding 4). If it doesn't confirm within its
                    // bounded retry, land in `.activating` rather than claiming the
                    // entitlement is fully live.
                    let serverConfirmed = await onPurchaseSuccess?() ?? false
                    purchaseState = serverConfirmed
                        ? .success(productID: productID)
                        : .activating(productID: productID)
                }

            case .userCancelled:
                Logger.quiz.info("🚫 StoreManager: User cancelled purchase")
                purchaseState = .cancelled

            case .pending:
                Logger.quiz.info("⏳ StoreManager: Purchase pending (Ask to Buy?)")
                purchaseState = .pending
            }
        } catch {
            purchaseError = error.localizedDescription
            purchaseState = .failed(message: error.localizedDescription)
            SentryLog.error("purchase failed", category: .quiz, attributes: ["product": productID, "error": String(describing: error)])
            Logger.quiz.error("❌ StoreManager: Purchase failed: \(error, privacy: .public)")
        }

        isLoading = false
    }

    /// Clears a finished purchase attempt back to `.idle` — the paywall calls
    /// this on appear so a previous attempt's outcome doesn't leak into a new
    /// presentation. No-op mid-purchase.
    func resetPurchaseState() {
        if case .purchasing = purchaseState { return }
        purchaseState = .idle
        purchaseError = nil
    }

    // MARK: - Restore Purchases

    /// Restores the RC-tracked subscription via StoreKit, then ALWAYS
    /// reconciles with the server — consumable packs have no StoreKit
    /// restore, so a pack buyer's only path back to their credits is the
    /// server re-deriving both subscription state and pack credits from
    /// RevenueCat's history (`POST /entitlements/sync`, issue #102 finding
    /// 3). Gating that call on `isPurchased` (as before) meant a pack-only
    /// buyer was silently told "nothing to restore" even though the server
    /// could have recovered their credits.
    func restorePurchases() async {
        isLoading = true
        purchaseError = nil

        do {
            try await purchaseService.restore()
            await checkPurchaseStatus()
            // The bridge reports whether the server mirror now shows an
            // active entitlement (subscription OR credits) — the only signal
            // that can see pack credits, since `isPurchased` never reflects them.
            let recoveredViaServer = await onPurchaseSuccess?() ?? false
            if isPurchased || recoveredViaServer {
                // Either the subscription itself came back, or the server
                // reconciliation surfaced something (pack credits, or a
                // subscription webhook that landed after the SDK check) —
                // either way this is a real recovery, not a no-op (#96 P1).
                purchaseState = .success(productID: nil)
            } else {
                purchaseState = .nothingToRestore
            }
        } catch {
            let message = String(localized: "Failed to restore purchases", comment: "Paywall error shown when restoring previous purchases failed")
            purchaseError = message
            purchaseState = .failed(message: message)
        }

        isLoading = false
    }

    // MARK: - Purchase Status

    func checkPurchaseStatus() async {
        isPurchased = await purchaseService.currentlyEntitled(entitlementId: StoreProduct.entitlementId)
    }

    // MARK: - Account Linking

    /// Aliases the RC identity to the durable account id on sign-in, so a pack
    /// or subscription bought anonymously merges into the signed-in account's
    /// RC history (issue #93 Session E must-do / D-review advisory).
    func logIn(accountId: String) async {
        await purchaseService.logIn(appUserID: accountId)
        await checkPurchaseStatus()
    }

    // MARK: - Entitlement Listener

    private func listenForEntitlementUpdates() -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            guard let self else { return }
            for await update in self.purchaseService.entitlementUpdates {
                if update.entitlementId == StoreProduct.entitlementId {
                    self.isPurchased = update.isActive
                }
            }
        }
    }
}
