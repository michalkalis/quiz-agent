//
//  PaywallViewInspectorTests.swift
//  HangsTests
//
//  #94 — Paywall synced to z8TS6 (plan picker) + Paywall-Offline (PouwN).
//
//  Why these tests matter:
//  - Token contract: the offline circle must use warning (amber), not pink —
//    wrong colour blurs the "connectivity issue" signal.
//  - The plan picker (Annual pre-selected, Monthly, one-time pack) only shows
//    in the normal paywall — regression here loses the upgrade pitch entirely.
//  - The single CTA must interpolate the *selected* plan's RC displayPrice —
//    a wrong billing-period suffix misstates what the user is buying.
//  - The auto-renew legal line is an App Store review requirement — its
//    absence can get a release rejected.
//  - The "CAN'T REACH THE STORE" headline and "Try Again" CTA only appear in
//    the offline variant — regression here silently breaks the offline UX.
//  - isOffline is a pure computed property on PaywallView; it drives which body
//    renders, so we test it directly without needing a full hosted view.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import UIKit
import ViewInspector

// MARK: - Helpers

@MainActor
private func makeStoreManager(
    offerings: PurchasableOfferings? = nil,
    hasAttemptedLoad: Bool = false
) async -> StoreManager {
    let mock = MockPurchaseService()
    mock.stubbedOfferings = offerings
    mock.stubbedIsEntitled = false
    let manager = StoreManager(purchaseService: mock)
    // Drain init Tasks so async state settles.
    await Task.yield()
    await Task.yield()
    // Override hasAttemptedOfferingsLoad for test scenarios by triggering
    // loadOfferings only when the test needs the "attempted but failed" state.
    if hasAttemptedLoad {
        await manager.loadOfferings()
    }
    return manager
}

private func makeLimitError(questionsLimit: Int = 10) -> QuotaLimitError {
    QuotaLimitError(
        error: "Daily limit reached",
        questionsUsed: questionsLimit,
        questionsLimit: questionsLimit,
        resetsAt: "2099-01-01T08:00:00.000Z",
        upgradeAvailable: true
    )
}

/// The full three-package offering (annual + monthly + pack) with distinct prices.
private func makeFullOfferings() -> PurchasableOfferings {
    PurchasableOfferings(
        monthly: PurchasableProduct(id: StoreProduct.monthlySubId, displayPrice: "€4.99", displayName: "Hangs Unlimited"),
        annual: PurchasableProduct(id: StoreProduct.annualSubId, displayPrice: "€29.99", displayName: "Hangs Unlimited Annual"),
        pack: PurchasableProduct(id: StoreProduct.packId, displayPrice: "€1.99", displayName: "100 Question Pack")
    )
}

/// True when any Text in the tree contains ALL the given fragments.
/// Interpolated LocalizedStringKey CTA labels are matched by fragments so the
/// assertion holds whether ViewInspector resolves the price or the %@ key.
@MainActor
private func treeHasText(_ tree: InspectableView<ViewType.ClassifiedView>, containing fragments: [String]) -> Bool {
    let texts = tree.findAll(ViewType.Text.self)
    return texts.contains { text in
        guard let value = try? text.string() else { return false }
        return fragments.allSatisfy { value.contains($0) }
    }
}

// MARK: - Token: warning colour for offline variant

@Suite("PaywallView — offline uses warning token")
struct PaywallViewOfflineTokenTests {
    @Test("Warning token resolves to amber #F59E0B in light mode")
    func warningTokenIsAmber() {
        let uiColor = UIColor(Theme.Hangs.Colors.warning)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: nil)
        let tol: CGFloat = 1.0 / 255.0 + 0.0001
        // #F59E0B = R:245 G:158 B:11
        #expect(abs(r - (245.0 / 255.0)) <= tol, "Red channel: \(r)")
        #expect(abs(g - (158.0 / 255.0)) <= tol, "Green channel: \(g)")
        #expect(abs(b - (11.0 / 255.0)) <= tol, "Blue channel: \(b)")
    }

    @Test("Warning token differs from pink — offline and upgrade signals are distinct")
    func warningDiffersFromPink() {
        #expect(
            Theme.Hangs.Colors.warning != Theme.Hangs.Colors.pink,
            "warning (#F59E0B) must differ from pink (#FF3D8F)"
        )
    }
}

// MARK: - isOffline logic

@MainActor
@Suite("PaywallView — isOffline state machine")
struct PaywallViewOfflineStateTests {
    @Test("isOffline false when product loaded")
    func notOfflineWhenProductLoaded() async {
        let manager = await makeStoreManager(offerings: makeFullOfferings(), hasAttemptedLoad: true)
        let view = PaywallView(storeManager: manager, limitError: nil, onDismiss: {})
        #expect(!view.isOffline, "product loaded → normal paywall, not offline variant")
    }

    @Test("isOffline true when load attempted but product nil")
    func offlineAfterFailedLoad() async {
        // MockPurchaseService returns nil by default; calling loadOfferings sets hasAttemptedOfferingsLoad.
        let manager = await makeStoreManager(offerings: nil, hasAttemptedLoad: true)
        let view = PaywallView(storeManager: manager, limitError: nil, onDismiss: {})
        #expect(view.isOffline, "load attempted + product nil → PouwN offline variant")
    }
}

// MARK: - Normal paywall structure (z8TS6)

@MainActor
@Suite("PaywallView — normal paywall structure (z8TS6)")
struct PaywallViewNormalStructureTests {
    @Test("'GO UNLIMITED' headline renders in both quota-hit and proactive modes")
    func headlineRendersInBothModes() async throws {
        let manager = await makeStoreManager(offerings: makeFullOfferings(), hasAttemptedLoad: true)
        for limitError in [makeLimitError(), nil] {
            let view = PaywallView(storeManager: manager, limitError: limitError, onDismiss: {})
            try await ViewHosting.host(view) {
                let tree = try view.inspect()
                #expect(throws: Never.self) { try tree.find(text: "GO UNLIMITED") }
            }
        }
    }

    // #93 subscription IAP: proactive entry (Home card / Settings row) presents
    // with limitError nil — the paywall must pitch the upgrade, not falsely
    // claim the user ran out of questions.
    @Test("Proactive mode (limitError nil) shows upgrade pitch, not limit-reached copy")
    func proactiveModeShowsUpgradePitch() async throws {
        let manager = await makeStoreManager(offerings: makeFullOfferings(), hasAttemptedLoad: true)
        let view = PaywallView(storeManager: manager, limitError: nil, onDismiss: {})
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "Unlimited questions for every drive, no monthly cap.")
            }
            #expect(!treeHasText(tree, containing: ["free questions this month"]),
                    "quota copy must not show on proactive entry")
        }
    }

    @Test("limitMessage includes questionsLimit from QuotaLimitError")
    func limitMessageIncludesCount() async throws {
        let manager = await makeStoreManager(offerings: makeFullOfferings(), hasAttemptedLoad: true)
        let view = PaywallView(storeManager: manager, limitError: makeLimitError(questionsLimit: 10), onDismiss: {})
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "You've used all 10 free questions this month.")
            }
        }
    }

    @Test("Countdown pill renders when limitError has a resetDate")
    func countdownPillRenders() async throws {
        let manager = await makeStoreManager(offerings: makeFullOfferings(), hasAttemptedLoad: true)
        let view = PaywallView(storeManager: manager, limitError: makeLimitError(), onDismiss: {})
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(treeHasText(tree, containing: ["reset in"]), "No countdown text found")
        }
    }
}

// MARK: - Plan picker (z8TS6)

@MainActor
@Suite("PaywallView — plan picker (z8TS6)")
struct PaywallViewPlanPickerTests {
    @Test("Annual and Monthly plan cards render with the save badge")
    func planCardsRender() async throws {
        let manager = await makeStoreManager(offerings: makeFullOfferings(), hasAttemptedLoad: true)
        let view = PaywallView(storeManager: manager, limitError: nil, onDismiss: {})
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "Annual") }
            #expect(throws: Never.self) { try tree.find(text: "Monthly") }
            #expect(throws: Never.self) { try tree.find(text: "SAVE 50%") }
        }
    }

    @Test("Annual is pre-selected — CTA carries the yearly billing suffix")
    func annualPreselectedCTA() async throws {
        let manager = await makeStoreManager(offerings: makeFullOfferings(), hasAttemptedLoad: true)
        let view = PaywallView(storeManager: manager, limitError: nil, onDismiss: {})
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(treeHasText(tree, containing: ["Subscribe —", "/ year"]),
                    "default CTA must sell the annual plan")
            #expect(!treeHasText(tree, containing: ["Subscribe —", "/ month"]),
                    "monthly suffix must not show while annual is selected")
        }
    }

    @Test("Monthly selection drives the CTA to the monthly billing suffix")
    func monthlySelectionCTA() async throws {
        let manager = await makeStoreManager(offerings: makeFullOfferings(), hasAttemptedLoad: true)
        let view = PaywallView(storeManager: manager, limitError: nil, onDismiss: {}, initialPlan: .monthly)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(treeHasText(tree, containing: ["Subscribe —", "/ month"]),
                    "CTA must sell the monthly plan when monthly is selected")
            #expect(!treeHasText(tree, containing: ["Subscribe —", "/ year"]),
                    "yearly suffix must not show while monthly is selected")
        }
    }

    @Test("Missing annual package falls back to monthly (partial offerings)")
    func partialOfferingsFallback() async {
        let monthlyOnly = PurchasableOfferings(
            monthly: PurchasableProduct(id: StoreProduct.monthlySubId, displayPrice: "€4.99", displayName: "Hangs Unlimited"),
            annual: nil,
            pack: nil
        )
        let manager = await makeStoreManager(offerings: monthlyOnly, hasAttemptedLoad: true)
        let view = PaywallView(storeManager: manager, limitError: nil, onDismiss: {})
        #expect(view.effectivePlan == .monthly,
                "annual selected but unavailable → CTA must fall back to monthly, not dead-end")
    }

    @Test("One-time pack card renders with its non-subscription framing")
    func packCardRenders() async throws {
        let manager = await makeStoreManager(offerings: makeFullOfferings(), hasAttemptedLoad: true)
        let view = PaywallView(storeManager: manager, limitError: nil, onDismiss: {})
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "100 Question Pack") }
            #expect(throws: Never.self) { try tree.find(text: "One-time purchase · never expires") }
            #expect(throws: Never.self) { try tree.find(text: "or top up without subscribing") }
        }
    }

    @Test("Auto-renew legal line renders — App Store review requirement")
    func legalLineRenders() async throws {
        let manager = await makeStoreManager(offerings: makeFullOfferings(), hasAttemptedLoad: true)
        let view = PaywallView(storeManager: manager, limitError: nil, onDismiss: {})
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "Auto-renews until cancelled. Cancel anytime in Settings.")
            }
        }
    }
}

// MARK: - Offline paywall structure (PouwN)

@MainActor
@Suite("PaywallView — offline variant structure (PouwN)")
struct PaywallViewOfflineStructureTests {
    @Test("'CAN'T REACH THE STORE' headline renders in offline variant")
    func offlineHeadlineRenders() async throws {
        let manager = await makeStoreManager(offerings: nil, hasAttemptedLoad: true)
        let view = PaywallView(storeManager: manager, limitError: nil, onDismiss: {})
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "CAN'T REACH\nTHE STORE") }
        }
    }

    @Test("'Try Again' CTA renders in offline variant")
    func tryAgainCTARenders() async throws {
        let manager = await makeStoreManager(offerings: nil, hasAttemptedLoad: true)
        let view = PaywallView(storeManager: manager, limitError: nil, onDismiss: {})
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "Try Again") }
        }
    }

    @Test("'GO UNLIMITED' headline absent in offline variant")
    func paywallHeadlineAbsentWhenOffline() async throws {
        let manager = await makeStoreManager(offerings: nil, hasAttemptedLoad: true)
        let view = PaywallView(storeManager: manager, limitError: nil, onDismiss: {})
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) { try tree.find(text: "GO UNLIMITED") }
        }
    }

    @Test("Plan picker absent in offline variant")
    func planPickerAbsentWhenOffline() async throws {
        let manager = await makeStoreManager(offerings: nil, hasAttemptedLoad: true)
        let view = PaywallView(storeManager: manager, limitError: nil, onDismiss: {})
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) { try tree.find(text: "Annual") }
            #expect(throws: (any Error).self) { try tree.find(text: "100 Question Pack") }
        }
    }
}
