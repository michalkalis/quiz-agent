//
//  StoreManager.swift
//  Hangs
//
//  StoreKit 2 integration for freemium paywall.
//  Non-consumable "Hangs Unlimited" purchase.
//
//  StoreManager is the orchestrator: it manages @Published state and
//  coordinates calls through an injected PurchaseService protocol.
//  LivePurchaseService (default) delegates to real StoreKit 2 APIs.
//  MockPurchaseService enables daemon-free unit tests.
//

import Combine
import Foundation
import os

/// Product identifiers
enum StoreProduct {
    static let unlimited = "com.carquiz.unlimited"
}

/// Manages in-app purchases via StoreKit 2
@MainActor
final class StoreManager: ObservableObject {
    @Published private(set) var product: PurchasableProduct?
    @Published private(set) var isPurchased: Bool = false
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var hasAttemptedProductLoad: Bool = false
    @Published var purchaseError: String?

    private let purchaseService: PurchaseService
    private var transactionListener: Task<Void, Never>?

    /// Default initializer — uses LivePurchaseService backed by real StoreKit.
    /// Preserves callsite compatibility: `StoreManager()` continues to work.
    init() {
        purchaseService = LivePurchaseService()
        transactionListener = nil
        transactionListener = listenForTransactions()
        Task { await loadProduct() }
        Task { await checkPurchaseStatus() }
    }

    /// Testable initializer — injects a PurchaseService (e.g. MockPurchaseService).
    init(purchaseService: PurchaseService) {
        self.purchaseService = purchaseService
        transactionListener = nil
        transactionListener = listenForTransactions()
        Task { await loadProduct() }
        Task { await checkPurchaseStatus() }
    }

    deinit {
        transactionListener?.cancel()
    }

    // MARK: - Product Loading

    func loadProduct() async {
        let loaded = await purchaseService.loadProduct(id: StoreProduct.unlimited)
        product = loaded
        hasAttemptedProductLoad = true
        if loaded == nil {
            Logger.quiz.error("❌ StoreManager: Product not found or unavailable")
        }
    }

    // MARK: - Purchase

    func purchase() async {
        guard product != nil else {
            purchaseError = String(localized: "Product not available", comment: "Paywall error shown when the in-app purchase product failed to load")
            return
        }

        isLoading = true
        purchaseError = nil

        do {
            let outcome = try await purchaseService.purchase(productID: StoreProduct.unlimited)

            switch outcome {
            case .success:
                isPurchased = true
                Logger.quiz.info("✅ StoreManager: Purchase successful")

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
        isPurchased = await purchaseService.currentlyEntitled(productID: StoreProduct.unlimited)
    }

    // MARK: - Transaction Listener

    private func listenForTransactions() -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            guard let self else { return }
            for await update in self.purchaseService.entitlementUpdates {
                if update.productID == StoreProduct.unlimited && update.isVerified {
                    self.isPurchased = true
                }
            }
        }
    }
}

enum StoreError: LocalizedError {
    case failedVerification

    var errorDescription: String? {
        "Purchase verification failed"
    }
}
