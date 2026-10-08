//
//  PaywallPickerStateTests.swift
//  HangsTests
//
//  #194 A1: the paywall picker rules and the reset countdown moved out of
//  PaywallView (`PaywallPickerState`, `ResetCountdown`,
//  `QuotaLimitError.resetDate`). The redesign restyles the paywall; these pin
//  what the CTA buys and how the cards read while the store is busy, so a new
//  layout cannot charge for the wrong product or let a second purchase start.
//

import Foundation
@testable import Hangs
import Testing

private let monthly = PurchasableProduct(id: StoreProduct.monthlySubId, displayPrice: "€4.99", displayName: "Monthly")
private let pack = PurchasableProduct(id: StoreProduct.packId, displayPrice: "€2.99", displayName: "Pack")
private let full = PurchasableOfferings(monthly: monthly, pack: pack)

@Suite("Paywall picker rules (#194 A1)")
@MainActor
struct PaywallPickerStateTests {
    @Test("the CTA buys the selected plan, and falls back to monthly when the pack disappears")
    func effectivePlanAndProduct() {
        let packSelected = PaywallPickerState(selectedPlan: .pack, offerings: full, purchaseState: .idle)
        #expect(packSelected.effectivePlan == .pack)
        #expect(packSelected.selectedProduct == pack)

        let packDropped = PaywallPickerState(
            selectedPlan: .pack,
            offerings: PurchasableOfferings(monthly: monthly, pack: nil),
            purchaseState: .idle
        )
        #expect(packDropped.effectivePlan == .monthly, "never point the CTA at a product that is gone")
        #expect(packDropped.selectedProduct == monthly)

        let noOfferings = PaywallPickerState(selectedPlan: .monthly, offerings: nil, purchaseState: .idle)
        #expect(noOfferings.selectedProduct == nil)
    }

    @Test("purchasing and restoring make the store busy; outcomes do not")
    func busyStates() {
        func busy(_ state: PurchaseState) -> Bool {
            PaywallPickerState(selectedPlan: .monthly, offerings: full, purchaseState: state).isBusy
        }
        #expect(busy(.purchasing(productID: StoreProduct.monthlySubId)))
        #expect(busy(.restoring))
        #expect(!busy(.idle))
        #expect(!busy(.success(productID: nil)))
        #expect(!busy(.activating(productID: nil)))
        #expect(!busy(.failed(message: "x")))
        #expect(!busy(.cancelled))
    }

    /// #129 decision 2: the card being bought stays bright with a full check;
    /// the selected card whose product is NOT in flight demotes to a hollow
    /// check and dims; an unselected card never shows a check.
    @Test("cards read solid, hollow or none from the selection and the product in flight")
    func cardChecksWhileBusy() {
        let idle = PaywallPickerState(selectedPlan: .monthly, offerings: full, purchaseState: .idle)
        #expect(idle.check(for: .monthly) == .solid)
        #expect(idle.check(for: .pack) == .none)
        #expect(!idle.isDimmed(.monthly) && !idle.isDimmed(.pack))

        let buyingMonthly = PaywallPickerState(
            selectedPlan: .monthly, offerings: full,
            purchaseState: .purchasing(productID: StoreProduct.monthlySubId)
        )
        #expect(buyingMonthly.isPurchasing(.monthly))
        #expect(buyingMonthly.check(for: .monthly) == .solid)
        #expect(!buyingMonthly.isDimmed(.monthly))
        #expect(buyingMonthly.isDimmed(.pack))

        let restoring = PaywallPickerState(selectedPlan: .pack, offerings: full, purchaseState: .restoring)
        #expect(restoring.check(for: .pack) == .hollow)
        #expect(restoring.isDimmed(.pack) && restoring.isDimmed(.monthly))
    }

    @Test("the countdown reads days+hours, hours+minutes, minutes, then now")
    func countdownText() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func text(_ seconds: TimeInterval) -> String {
            ResetCountdown.text(until: now.addingTimeInterval(seconds), now: now)
        }
        #expect(text(12 * 86400 + 4 * 3600 + 59) == "12d 4h")
        #expect(text(3 * 3600 + 5 * 60 + 30) == "3h 5m")
        #expect(text(5 * 60 + 59) == "5m")
        let nowValue = String(localized: "now", comment: "Countdown pill value when free questions reset imminently")
        #expect(text(0) == nowValue)
        #expect(text(-60) == nowValue)
        #expect(ResetCountdown.refreshInterval == .seconds(60))
    }

    @Test("the quota reset time parses with and without fractional seconds")
    func quotaResetDateParsing() {
        func limit(_ resetsAt: String) -> QuotaLimitError {
            QuotaLimitError(error: "", questionsUsed: 30, questionsLimit: 30, resetsAt: resetsAt, upgradeAvailable: true)
        }
        let expected = Date(timeIntervalSince1970: 4_070_908_800) // 2099-01-01T00:00:00Z
        #expect(limit("2099-01-01T00:00:00.000Z").resetDate == expected)
        #expect(limit("2099-01-01T00:00:00+00:00").resetDate == expected)
        #expect(limit("not a date").resetDate == nil)
    }
}
