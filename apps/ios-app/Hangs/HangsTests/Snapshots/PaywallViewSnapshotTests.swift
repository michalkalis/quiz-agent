//
//  PaywallViewSnapshotTests.swift
//  HangsTests
//
//  Task 4.2 (issue #31): .dump snapshot baselines for two structurally-distinct
//  variants of PaywallView.
//
//  Chosen variants and rationale:
//
//  A. limitErrorWithCountdown — DailyLimitError supplied, product loaded ($4.99).
//     The CountdownToReset subview (HStack with clock Image + Text) is present
//     in the Mirror tree, and PrimaryButton carries the display-price string.
//
//  B. noLimitErrorProductLoading — limitError nil, product nil (isLoading: true).
//     CountdownToReset is entirely absent from the dump, and PrimaryButton uses
//     the loading-spinner variant (isLoading: true, no price string).
//
//  These two produce the most different .dump output because an entire subview
//  subtree (CountdownToReset) appears/disappears (criterion B from the issue),
//  AND the PrimaryButton arguments differ (criterion A). Both differences are
//  visible under Mirror reflection, which drives .dump.
//
//  Strategy: .dump (text-based, deterministic, Xcode/iOS-version agnostic,
//  reviewable in code-review). No image rendering involved.
//

import Foundation
import SnapshotTesting
import Testing
@testable import Hangs

// MARK: - Helpers

/// Build a stable StoreManager via MockPurchaseService.
/// Two Task.yield() calls drain the unstructured init Tasks so @Published
/// state is consistent before snapshot capture.
@MainActor
private func makeStoreManager(
    product: PurchasableProduct? = nil
) async -> StoreManager {
    let mock = MockPurchaseService()
    mock.stubbedProduct = product
    mock.stubbedIsEntitled = false
    let manager = StoreManager(purchaseService: mock)
    await Task.yield()
    await Task.yield()
    return manager
}

/// Build a DailyLimitError with a reset time ~8 hours from a fixed epoch
/// so the dump contains a deterministic resetsAt string (not wall-clock dependent).
private func makeLimitError() -> DailyLimitError {
    DailyLimitError(
        error: "Daily limit reached",
        questionsUsed: 5,
        questionsLimit: 5,
        resetsAt: "2099-01-01T08:00:00.000Z",
        upgradeAvailable: true
    )
}

// MARK: - Suite

@Suite("PaywallView Snapshot Tests")
@MainActor
struct PaywallViewSnapshotTests {

    // MARK: - Variant A: limitError present, product loaded

    /// PaywallView with:
    ///   • limitError supplied → CountdownToReset HStack present in dump
    ///   • StoreManager.product set → PrimaryButton carries "Unlock Unlimited — $4.99"
    @Test("Snapshot: limit-error with countdown and product loaded")
    func limitErrorWithCountdown() async {
        let product = PurchasableProduct(
            id: StoreProduct.unlimited,
            displayPrice: "$4.99",
            displayName: "Hangs Unlimited"
        )
        let manager = await makeStoreManager(product: product)
        let limitError = makeLimitError()

        let view = PaywallView(
            storeManager: manager,
            limitError: limitError,
            onDismiss: {}
        )

        assertSnapshot(of: view, as: .dump)
    }

    // MARK: - Variant B: no limit-error, product not yet loaded

    /// PaywallView with:
    ///   • limitError nil → CountdownToReset entirely absent from dump
    ///   • StoreManager.product nil → PrimaryButton uses loading branch (isLoading: true,
    ///     no price string) — the `else` branch of `if let product = storeManager.product`
    @Test("Snapshot: no limit-error, product loading")
    func noLimitErrorProductLoading() async {
        let manager = await makeStoreManager(product: nil)

        let view = PaywallView(
            storeManager: manager,
            limitError: nil,
            onDismiss: {}
        )

        assertSnapshot(of: view, as: .dump)
    }
}
