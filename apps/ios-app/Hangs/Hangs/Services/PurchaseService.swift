//
//  PurchaseService.swift
//  Hangs
//
//  Domain types and protocol for StoreKit operations.
//  LivePurchaseService wraps StoreKit 2 APIs; MockPurchaseService enables
//  daemon-free unit tests.
//
//  Background: SKTestSession on iOS 26 simulator hits a confirmed Apple-side
//  regression (SKInternalErrorDomain Code=3; Flutter #184678; Apple Developer
//  Forum thread/808030, May 2026). This protocol abstraction pushes all daemon-
//  dependent work into LivePurchaseService so StoreManager logic can be tested
//  without a live StoreKit daemon.
//

import Foundation
import StoreKit
import os

// MARK: - Domain Types

/// A product available for purchase — daemon-free alternative to StoreKit's
/// `Product`, which has no public initializer and cannot be created in tests.
struct PurchasableProduct: Sendable, Equatable {
    let id: String
    let displayPrice: String
    let displayName: String
}

/// The outcome of a purchase attempt.
enum PurchaseOutcome: Sendable {
    case success
    case userCancelled
    case pending
}

/// A single entitlement-update event emitted by the transaction listener.
struct EntitlementUpdate: Sendable {
    let productID: String
    let isVerified: Bool
}

// MARK: - Protocol

/// Abstracts StoreKit 2 operations behind a testable interface.
/// All methods are @MainActor — StoreManager is @MainActor and drives calls.
@MainActor
protocol PurchaseService: AnyObject, Sendable {
    /// Fetches the product for the given identifier and returns a domain type.
    func loadProduct(id: String) async -> PurchasableProduct?

    /// Attempts to purchase the product identified by `productID`.
    /// - Throws: `StoreError` on verification failure, or any StoreKit error.
    func purchase(productID: String) async throws -> PurchaseOutcome

    /// Syncs the App Store receipt — used for restore purchases.
    func restore() async throws

    /// Returns `true` if the user currently holds a verified entitlement
    /// for `productID`.
    func currentlyEntitled(productID: String) async -> Bool

    /// Long-lived stream of entitlement updates from `Transaction.updates`.
    var entitlementUpdates: AsyncStream<EntitlementUpdate> { get }
}

// MARK: - LivePurchaseService

/// Production implementation — delegates to StoreKit 2 APIs.
@MainActor
final class LivePurchaseService: PurchaseService {

    // Cache the real StoreKit Product so purchase() can call product.purchase().
    private var cachedProduct: Product?

    // Backing storage for the AsyncStream continuation.
    private let continuation: AsyncStream<EntitlementUpdate>.Continuation
    let entitlementUpdates: AsyncStream<EntitlementUpdate>

    // Background task that forwards Transaction.updates into the stream.
    private var listenerTask: Task<Void, Never>?

    init() {
        var cont: AsyncStream<EntitlementUpdate>.Continuation!
        self.entitlementUpdates = AsyncStream { cont = $0 }
        self.continuation = cont

        listenerTask = Task(priority: .background) { @MainActor [weak self] in
            for await result in Transaction.updates {
                if case .verified(let tx) = result {
                    await tx.finish()
                    self?.continuation.yield(
                        EntitlementUpdate(productID: tx.productID, isVerified: true)
                    )
                } else if case .unverified(let tx, _) = result {
                    self?.continuation.yield(
                        EntitlementUpdate(productID: tx.productID, isVerified: false)
                    )
                }
            }
        }
    }

    deinit {
        listenerTask?.cancel()
        continuation.finish()
    }

    func loadProduct(id: String) async -> PurchasableProduct? {
        do {
            let products = try await Product.products(for: [id])
            if let p = products.first {
                cachedProduct = p
                return PurchasableProduct(
                    id: p.id,
                    displayPrice: p.displayPrice,
                    displayName: p.displayName
                )
            }
        } catch {
            Logger.quiz.error("❌ LivePurchaseService: loadProduct failed: \(error, privacy: .public)")
        }
        return nil
    }

    func purchase(productID: String) async throws -> PurchaseOutcome {
        // Re-use cached product or fetch fresh.
        if cachedProduct?.id != productID {
            cachedProduct = nil
        }
        if cachedProduct == nil {
            let products = try await Product.products(for: [productID])
            cachedProduct = products.first
        }
        guard let product = cachedProduct else {
            throw StoreError.failedVerification
        }

        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await transaction.finish()
            return .success
        case .userCancelled:
            return .userCancelled
        case .pending:
            return .pending
        @unknown default:
            return .userCancelled
        }
    }

    func restore() async throws {
        try await AppStore.sync()
    }

    func currentlyEntitled(productID: String) async -> Bool {
        for await result in Transaction.currentEntitlements {
            if case .verified(let tx) = result, tx.productID == productID {
                return true
            }
        }
        return false
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
