//
//  PaywallPickerState.swift
//  Hangs
//
//  The paywall plan picker's rules (#179 finding 9, #129): which plan the CTA
//  buys, what the store is doing, and how each card reads while it does.
//  Derived from the picker selection + StoreManager; moved out of PaywallView
//  in #194 A1 so the redesign restyles the cards without changing the rules.
//

import Foundation

struct PaywallPickerState {
    /// What the store is doing right now, derived from `purchaseState` — the
    /// single source the whole in-flight paywall renders from. During any of
    /// these the CTA spins and every purchase trigger dims + disables (no
    /// second purchase can start).
    enum Activity: Equatable {
        case idle
        case purchasing(productID: String)
        case restoring
    }

    /// The pink selection radio, demoted (#129 decision 2) to a hollow outline
    /// when the card stays selected while a *different* product is in flight.
    enum Check { case none, solid, hollow }

    let selectedPlan: PaywallPlan
    let offerings: PurchasableOfferings?
    let purchaseState: PurchaseState
    /// False when the server says the user already holds the only plan (a
    /// subscriber who spent the month's allowance, `upgrade_available: false`):
    /// the subscription is never offered, the pack is the one thing to buy.
    var monthlyOffered = true

    /// The plan the CTA buys. The pack card only renders when the pack exists,
    /// but an offering refresh could drop it under the selection — never leave
    /// the CTA pointing at a product that is gone.
    var effectivePlan: PaywallPlan {
        switch selectedPlan {
        case .monthly:
            return monthlyOffered || offerings?.pack == nil ? .monthly : .pack
        case .pack:
            guard offerings?.pack != nil else { return .monthly }
            return .pack
        }
    }

    /// Nil for the subscription when it is not on offer, so no CTA can ever
    /// sell a plan to someone who already has it.
    var selectedProduct: PurchasableProduct? {
        switch effectivePlan {
        case .monthly: return monthlyOffered ? offerings?.monthly : nil
        case .pack: return offerings?.pack
        }
    }

    var activity: Activity {
        switch purchaseState {
        case let .purchasing(id): return .purchasing(productID: id)
        case .restoring: return .restoring
        default: return .idle
        }
    }

    /// True while any store operation is in flight — gates dimming + disabling.
    var isBusy: Bool { activity != .idle }

    static func productID(for plan: PaywallPlan) -> String {
        switch plan {
        case .monthly: return StoreProduct.monthlySubId
        case .pack: return StoreProduct.packId
        }
    }

    /// The card whose product is the exact one being purchased (stays bright
    /// with a full check — the highlight is correct here).
    func isPurchasing(_ plan: PaywallPlan) -> Bool {
        activity == .purchasing(productID: Self.productID(for: plan))
    }

    /// A card recedes when the store is busy and it is not the subject of the
    /// current operation.
    func isDimmed(_ plan: PaywallPlan) -> Bool {
        isBusy && !isPurchasing(plan)
    }

    func check(for plan: PaywallPlan) -> Check {
        guard effectivePlan == plan else { return .none }
        return isDimmed(plan) ? .hollow : .solid
    }
}
