//
//  PackPurchaseService.swift
//  Hangs
//
//  StoreKit 2 purchase of the custom-pack product (issue #140). Deliberately
//  NOT RevenueCat: quiz-pack-api authorises an order from the raw Apple JWS
//  (`X-StoreKit-JWS`), and RevenueCat's SDK keeps `jwsRepresentation` internal —
//  only a direct `Product.purchase()` hands us the signed transaction to
//  forward. Subscriptions and the #93 credit pack stay on RevenueCat; this
//  service owns exactly one consumable.
//
//  Crash-safety: the proof is persisted BEFORE the transaction is finished, so
//  a purchase whose order POST never completed (app death, network) is retried
//  from `pendingProof()` instead of charging the user again. Finishing right
//  after persisting also keeps RevenueCat's launch-time sweep of unfinished
//  transactions from racing us for it.
//

import Foundation
import StoreKit

// MARK: - Payment proof

/// A completed StoreKit purchase, ready to authorise `POST /v1/orders`:
/// the raw JWS plus the transaction fields the server cross-checks against
/// the request body (`orders.py`).
nonisolated struct PackPaymentProof: Codable, Equatable, Sendable {
    let transactionId: String
    let productId: String
    let jws: String
}

// MARK: - Protocol

/// StoreKit purchase of the custom-pack product.
protocol PackPurchaseServiceProtocol: Sendable {
    /// Run the App Store payment sheet for the pack product and return the
    /// proof. The proof is durably persisted before this returns; call
    /// `clearPendingProof()` once the backend has accepted the order.
    func purchase() async throws -> PackPaymentProof
    /// Proof of an earlier purchase whose order was never accepted by the
    /// backend (crash/network between payment and order creation). Reuse it
    /// instead of purchasing again — the server replays idempotently.
    func pendingProof() -> PackPaymentProof?
    /// Forget the persisted proof after the backend accepted the order.
    func clearPendingProof()
}

enum PackPurchaseError: LocalizedError, Equatable {
    /// The App Store returned no product for the pack id (not yet configured
    /// in App Store Connect, or store outage).
    case productUnavailable
    /// The user dismissed the payment sheet — not charged.
    case cancelled
    /// Purchase awaiting approval (Ask to Buy / SCA) — may complete later.
    case pending
    /// StoreKit handed back a transaction that failed local verification.
    case unverified

    var errorDescription: String? {
        switch self {
        case .productUnavailable:
            return String(localized: "The pack product isn't available right now. Please try again later.", comment: "Pack purchase error: App Store returned no product for the custom-pack id")
        case .cancelled:
            return String(localized: "Purchase cancelled. You have not been charged.", comment: "Pack purchase error: user dismissed the App Store payment sheet")
        case .pending:
            return String(localized: "Your purchase is awaiting approval. Once it's approved, come back and try again.", comment: "Pack purchase error: Ask to Buy / pending authorization")
        case .unverified:
            return String(localized: "The App Store receipt could not be verified. Please try again.", comment: "Pack purchase error: StoreKit verification of the transaction failed")
        }
    }
}

// MARK: - Pending-proof store

/// Durable slot for the one in-flight purchase proof (UserDefaults, JSON).
/// The JWS is not a secret — it is a signed receipt the server independently
/// verifies — so Keychain hardening isn't needed here.
nonisolated struct PendingPackPurchaseStore: Sendable {
    private static let key = "pending_pack_purchase_proof"
    /// nil → the app's standard defaults; tests inject an isolated suite name.
    /// Held as a name (not a `UserDefaults`, which isn't Sendable) — the
    /// thread-safe defaults object is resolved per access.
    private let suiteName: String?

    init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    func load() -> PackPaymentProof? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(PackPaymentProof.self, from: data)
    }

    func save(_ proof: PackPaymentProof) {
        guard let data = try? JSONEncoder().encode(proof) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}

// MARK: - Live implementation

final class StoreKitPackPurchaseService: PackPurchaseServiceProtocol, Sendable {
    /// The App Store product id — must equal a `_PRODUCT_TIERS` key on the
    /// server (`orders.py`), because the backend cross-checks the JWS's
    /// productId against the order body. Single tier today, mirroring
    /// `PackOrderService.productId`.
    static let productId = "pack_30"

    private let store: PendingPackPurchaseStore

    init(store: PendingPackPurchaseStore = PendingPackPurchaseStore()) {
        self.store = store
    }

    func purchase() async throws -> PackPaymentProof {
        guard let product = try await Product.products(for: [Self.productId]).first else {
            throw PackPurchaseError.productUnavailable
        }

        let result = try await product.purchase()
        switch result {
        case let .success(verification):
            guard case let .verified(transaction) = verification else {
                throw PackPurchaseError.unverified
            }
            let proof = PackPaymentProof(
                transactionId: String(transaction.id),
                productId: transaction.productID,
                jws: verification.jwsRepresentation
            )
            // Persist FIRST — once finished, a consumable transaction cannot be
            // re-read from StoreKit, so the durable proof is the only recovery
            // path if the order POST never lands.
            store.save(proof)
            await transaction.finish()
            return proof
        case .userCancelled:
            throw PackPurchaseError.cancelled
        case .pending:
            throw PackPurchaseError.pending
        @unknown default:
            throw PackPurchaseError.productUnavailable
        }
    }

    func pendingProof() -> PackPaymentProof? {
        store.load()
    }

    func clearPendingProof() {
        store.clear()
    }
}
