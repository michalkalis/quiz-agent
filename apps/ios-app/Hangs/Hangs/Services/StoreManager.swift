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

        do {
            let outcome = try await purchaseService.purchase(productID: productID)

            switch outcome {
            case .success:
                Logger.quiz.info("✅ StoreManager: Purchase successful")
                // Re-derive from the SDK rather than assuming — a pack purchase
                // must not flip isPurchased, and this also catches an already-
                // entitled subscriber buying the other billing period.
                await checkPurchaseStatus()

            case .userCancelled:
                Logger.quiz.info("🚫 StoreManager: User cancelled purchase")

            case .pending:
                Logger.quiz.info("⏳ StoreManager: Purchase pending (Ask to Buy?)")
            }
        } catch {
            purchaseError = error.localizedDescription
            Logger.quiz.error("❌ StoreManager: Purchase failed: \(error, privacy: .public)")
        }

        isLoading = false
    }

    // MARK: - Restore Purchases

    /// Restores the subscription only — consumable packs have no StoreKit
    /// restore; their balance lives server-side in the credit ledger.
    func restorePurchases() async {
        isLoading = true
        purchaseError = nil

        do {
            try await purchaseService.restore()
            await checkPurchaseStatus()
        } catch {
            purchaseError = String(localized: "Failed to restore purchases", comment: "Paywall error shown when restoring previous purchases failed")
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
