//
//  AppScreen+Paywall.swift
//  HangsTests
//
//  #194 C6: paywall states the hero suite does not freeze — opened from Home
//  (no quota wall) with the one-time pack selected, and the store unreachable.
//  #199: a Trubbo Plus subscriber who spent the month's allowance (only the
//  pack on offer).
//

import Foundation
@testable import Hangs
import SwiftUI

extension AppScreen {
    func makePaywall() async -> AnyView {
        let purchases = MockPurchaseService()
        purchases.stubbedIsEntitled = false
        switch self {
        case .paywallOffline:
            purchases.stubbedOfferings = nil
        default:
            purchases.stubbedOfferings = PurchasableOfferings(
                monthly: PurchasableProduct(id: StoreProduct.monthlySubId, displayPrice: "€4.99", displayName: "Trubbo Plus"),
                pack: PurchasableProduct(id: StoreProduct.packId, displayPrice: "€2.99", displayName: "100 Question Pack")
            )
        }
        let store = StoreManager(purchaseService: purchases)
        await store.loadOfferings()
        return AnyView(PaywallView(
            storeManager: store, limitError: limitError, onDismiss: {}, initialPlan: .pack
        ))
    }

    /// Only the spent subscriber has a 429 behind the paywall. Its reset is
    /// 12½ days out, like Home's, so the countdown pill reads the same each run.
    private var limitError: QuotaLimitError? {
        guard self == .paywallAllowanceSpent else { return nil }
        return QuotaLimitError(
            error: "quota_limit_reached", questionsUsed: 1000, questionsLimit: 1000,
            resetsAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(12 * 86400 + 12 * 3600)),
            upgradeAvailable: false
        )
    }
}
