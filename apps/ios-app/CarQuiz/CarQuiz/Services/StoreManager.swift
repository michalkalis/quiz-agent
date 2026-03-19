//
//  StoreManager.swift
//  CarQuiz
//
//  StoreKit 2 integration for freemium paywall
//  Non-consumable "CarQuiz Unlimited" purchase
//

import StoreKit

/// Product identifiers
enum StoreProduct {
    static let unlimited = "com.carquiz.unlimited"
}

/// Manages in-app purchases via StoreKit 2
@MainActor
final class StoreManager: ObservableObject {
    @Published private(set) var product: Product?
    @Published private(set) var isPurchased: Bool = false
    @Published private(set) var isLoading: Bool = false
    @Published var purchaseError: String?

    private var transactionListener: Task<Void, Never>?

    init() {
        transactionListener = listenForTransactions()
        Task { await loadProduct() }
        Task { await checkPurchaseStatus() }
    }

    deinit {
        transactionListener?.cancel()
    }

    // MARK: - Product Loading

    func loadProduct() async {
        do {
            let products = try await Product.products(for: [StoreProduct.unlimited])
            product = products.first
        } catch {
            if Config.verboseLogging {
                print("❌ StoreManager: Failed to load products: \(error)")
            }
        }
    }

    // MARK: - Purchase

    func purchase() async {
        guard let product else {
            purchaseError = "Product not available"
            return
        }

        isLoading = true
        purchaseError = nil

        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                isPurchased = true
                await transaction.finish()

                if Config.verboseLogging {
                    print("✅ StoreManager: Purchase successful")
                }

            case .userCancelled:
                if Config.verboseLogging {
                    print("🚫 StoreManager: User cancelled purchase")
                }

            case .pending:
                if Config.verboseLogging {
                    print("⏳ StoreManager: Purchase pending (Ask to Buy?)")
                }

            @unknown default:
                break
            }
        } catch {
            purchaseError = error.localizedDescription
            if Config.verboseLogging {
                print("❌ StoreManager: Purchase failed: \(error)")
            }
        }

        isLoading = false
    }

    // MARK: - Restore Purchases

    func restorePurchases() async {
        isLoading = true
        purchaseError = nil

        do {
            try await AppStore.sync()
            await checkPurchaseStatus()
        } catch {
            purchaseError = "Failed to restore purchases"
        }

        isLoading = false
    }

    // MARK: - Purchase Status

    func checkPurchaseStatus() async {
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == StoreProduct.unlimited {
                isPurchased = true
                return
            }
        }
        isPurchased = false
    }

    // MARK: - Transaction Listener

    private func listenForTransactions() -> Task<Void, Never> {
        Task(priority: .background) { @MainActor [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result {
                    await transaction.finish()
                    if transaction.productID == StoreProduct.unlimited {
                        self?.isPurchased = true
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.failedVerification
        case .verified(let safe):
            return safe
        }
    }
}

enum StoreError: LocalizedError {
    case failedVerification

    var errorDescription: String? {
        "Purchase verification failed"
    }
}
