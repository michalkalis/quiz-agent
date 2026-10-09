//
//  AppScreen+Paywall.swift
//  HangsTests
//
//  #194 C6: paywall states the hero suite does not freeze — opened from Home
//  (no quota wall) with the one-time pack selected, and the store unreachable.
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
                monthly: PurchasableProduct(id: StoreProduct.monthlySubId, displayPrice: "€4.99", displayName: "Hangs Unlimited"),
                pack: PurchasableProduct(id: StoreProduct.packId, displayPrice: "€2.99", displayName: "100 Question Pack")
            )
        }
        let store = StoreManager(purchaseService: purchases)
        await store.loadOfferings()
        return AnyView(PaywallView(storeManager: store, limitError: nil, onDismiss: {}, initialPlan: .pack))
    }
}
