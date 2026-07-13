//
//  PurchaseService.swift
//  Hangs
//
//  Domain types and protocol for in-app purchases.
//  LivePurchaseService wraps the RevenueCat SDK (issue #93); MockPurchaseService
//  enables daemon-free unit tests.
//
//  RevenueCat replaces the hand-rolled StoreKit 2 stack: it owns receipt/JWS
//  validation and subscription lifecycle, while the backend owns the credit
//  ledger + quota gate (server-side entitlement, never client-trusted).
//

import Foundation
import RevenueCat
import os

// MARK: - Domain Types

/// A single purchasable package (subscription or consumable) — daemon-free
/// alternative to RevenueCat's `Package`/`StoreProduct`, which can't be
/// constructed directly in tests.
struct PurchasableProduct: Sendable, Equatable {
    let id: String
    let displayPrice: String
    let displayName: String
}

/// The current RC `Offering`, split into the three pinned package roles
/// (issue #93 D-ids). Any of the three may be nil if not yet configured or
/// unreachable — callers must handle partial availability.
struct PurchasableOfferings: Sendable, Equatable {
    let monthly: PurchasableProduct?
    let annual: PurchasableProduct?
    let pack: PurchasableProduct?

    static let empty = PurchasableOfferings(monthly: nil, annual: nil, pack: nil)
}

/// The outcome of a purchase attempt.
///
/// `success` carries whether the `unlimited` entitlement is active in the
/// CustomerInfo returned by the purchase itself — a subscription purchase
/// whose sheet completed but whose entitlement did NOT activate must fail
/// loud instead of silently re-offering the paywall (#96 P1).
enum PurchaseOutcome: Sendable, Equatable {
    case success(unlimitedActive: Bool)
    case userCancelled
    case pending
}

/// A single entitlement-update event emitted by the customer-info listener.
struct EntitlementUpdate: Sendable {
    let entitlementId: String
    let isActive: Bool
}

// MARK: - Protocol

/// Abstracts RevenueCat operations behind a testable interface.
/// All methods are @MainActor — StoreManager is @MainActor and drives calls.
@MainActor
protocol PurchaseService: AnyObject, Sendable {
    /// Fetches the current offering and splits it into the pinned package roles.
    func loadOfferings() async -> PurchasableOfferings?

    /// Attempts to purchase the package identified by `productID` (must be one
    /// of the ids surfaced by `loadOfferings()`).
    /// - Throws: `StoreError` on verification failure, or any SDK error.
    func purchase(productID: String) async throws -> PurchaseOutcome

    /// Restores subscription purchases (consumable packs are never restored —
    /// their balance lives server-side in the credit ledger, issue #93 D-tables).
    func restore() async throws

    /// Returns `true` if the customer currently holds an active entitlement
    /// for `entitlementId`.
    func currentlyEntitled(entitlementId: String) async -> Bool

    /// Aliases the RC identity to the durable account id (anon or signed-in
    /// user), so purchase history made under the anon id merges on sign-in
    /// (issue #93 §2, Session E must-do).
    func logIn(appUserID: String) async

    /// Long-lived stream of entitlement updates from `Purchases.customerInfoStream`.
    var entitlementUpdates: AsyncStream<EntitlementUpdate> { get }
}

// MARK: - LivePurchaseService

/// Production implementation — delegates to the RevenueCat SDK.
@MainActor
final class LivePurchaseService: PurchaseService {

    /// Configures the RC SDK once per process. Safe to call multiple times —
    /// a no-op after the first successful configure. Call as early as
    /// possible at app launch, before any `Purchases.shared` access.
    static func configure(appUserID: String?) {
        guard !Purchases.isConfigured else { return }
        Purchases.logLevel = Config.isDebug ? .warn : .error
        Purchases.configure(withAPIKey: Config.revenueCatPublicSDKKey, appUserID: appUserID)
    }

    // Cache the current RC Offering so purchase() can resolve a package by id.
    private var cachedOffering: RevenueCat.Offering?

    // Backing storage for the AsyncStream continuation.
    private let continuation: AsyncStream<EntitlementUpdate>.Continuation
    let entitlementUpdates: AsyncStream<EntitlementUpdate>

    // Background task that forwards customerInfoStream into the domain stream.
    private var listenerTask: Task<Void, Never>?

    init() {
        var cont: AsyncStream<EntitlementUpdate>.Continuation!
        self.entitlementUpdates = AsyncStream { cont = $0 }
        self.continuation = cont

        listenerTask = Task(priority: .background) { @MainActor [weak self] in
            for await customerInfo in Purchases.shared.customerInfoStream {
                let isActive = customerInfo.entitlements[StoreProduct.entitlementId]?.isActive == true
                self?.continuation.yield(
                    EntitlementUpdate(entitlementId: StoreProduct.entitlementId, isActive: isActive)
                )
            }
        }
    }

    deinit {
        listenerTask?.cancel()
        continuation.finish()
    }

    func loadOfferings() async -> PurchasableOfferings? {
        do {
            let offerings = try await Purchases.shared.offerings()
            guard let current = offerings.current else {
                Logger.quiz.error("❌ LivePurchaseService: no current offering configured")
                return nil
            }
            cachedOffering = current
            return PurchasableOfferings(
                monthly: makeProduct(current.monthly),
                annual: makeProduct(current.annual),
                pack: makeProduct(current.package(identifier: StoreProduct.packPackageIdentifier))
            )
        } catch {
            Logger.quiz.error("❌ LivePurchaseService: loadOfferings failed: \(error, privacy: .public)")
            return nil
        }
    }

    private func makeProduct(_ package: RevenueCat.Package?) -> PurchasableProduct? {
        guard let package else { return nil }
        return PurchasableProduct(
            id: package.storeProduct.productIdentifier,
            displayPrice: package.storeProduct.localizedPriceString,
            displayName: package.storeProduct.localizedTitle
        )
    }

    func purchase(productID: String) async throws -> PurchaseOutcome {
        guard let package = cachedOffering?.availablePackages.first(where: { $0.storeProduct.productIdentifier == productID }) else {
            throw StoreError.failedVerification
        }

        let result = try await Purchases.shared.purchase(package: package)
        if result.userCancelled {
            return .userCancelled
        }
        let unlimitedActive =
            result.customerInfo.entitlements[StoreProduct.entitlementId]?.isActive == true
        return .success(unlimitedActive: unlimitedActive)
    }

    func restore() async throws {
        _ = try await Purchases.shared.restorePurchases()
    }

    func currentlyEntitled(entitlementId: String) async -> Bool {
        guard let info = try? await Purchases.shared.customerInfo() else { return false }
        return info.entitlements[entitlementId]?.isActive == true
    }

    func logIn(appUserID: String) async {
        do {
            _ = try await Purchases.shared.logIn(appUserID)
        } catch {
            Logger.quiz.error("❌ LivePurchaseService: RC logIn failed: \(error, privacy: .public)")
        }
    }
}

enum StoreError: LocalizedError {
    case failedVerification

    var errorDescription: String? {
        "Purchase verification failed"
    }
}
