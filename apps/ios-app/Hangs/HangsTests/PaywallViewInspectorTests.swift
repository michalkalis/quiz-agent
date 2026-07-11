//
//  PaywallViewInspectorTests.swift
//  HangsTests
//
//  #52 task 52.15 — Paywall (u2ySy) + Paywall-Offline (PouwN) redesign.
//
//  Why these tests matter:
//  - Token contract: the offline circle must use warning (amber), not pink —
//    wrong colour blurs the "connectivity issue" signal.
//  - The feature card ("unlimited" label + 3 checkrow texts) only shows in the
//    normal paywall, never the offline variant — regression here loses the
//    upgrade pitch entirely.
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
        let offerings = PurchasableOfferings(
            monthly: PurchasableProduct(id: StoreProduct.monthlySubId, displayPrice: "€4.99", displayName: "Hangs Unlimited"),
            annual: nil,
            pack: nil
        )
        let manager = await makeStoreManager(offerings: offerings, hasAttemptedLoad: true)
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

// MARK: - Normal paywall structure (u2ySy)

@MainActor
@Suite("PaywallView — normal paywall structure (u2ySy)")
struct PaywallViewNormalStructureTests {
    @Test("'OUT OF QUESTIONS' headline renders when the quota was hit")
    func outOfQuestionsHeadline() async throws {
        let offerings = PurchasableOfferings(
            monthly: PurchasableProduct(id: StoreProduct.monthlySubId, displayPrice: "€4.99", displayName: "Hangs Unlimited"),
            annual: nil,
            pack: nil
        )
        let manager = await makeStoreManager(offerings: offerings, hasAttemptedLoad: true)
        let view = PaywallView(storeManager: manager, limitError: makeLimitError(), onDismiss: {})
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "OUT OF\nQUESTIONS") }
        }
    }

    // #93 subscription IAP: proactive entry (Home card / Settings row) presents
    // with limitError nil — the paywall must pitch the upgrade, not falsely
    // claim the user ran out of questions.
    @Test("Proactive mode (limitError nil) shows upgrade pitch, not limit-reached copy")
    func proactiveModeShowsUpgradePitch() async throws {
        let offerings = PurchasableOfferings(
            monthly: PurchasableProduct(id: StoreProduct.monthlySubId, displayPrice: "€4.99", displayName: "Hangs Unlimited"),
            annual: nil,
            pack: nil
        )
        let manager = await makeStoreManager(offerings: offerings, hasAttemptedLoad: true)
        let view = PaywallView(storeManager: manager, limitError: nil, onDismiss: {})
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "GO\nUNLIMITED") }
            #expect(throws: (any Error).self) { try tree.find(text: "OUT OF\nQUESTIONS") }
        }
    }

    @Test("Feature card 'unlimited' label renders")
    func featureCardLabelRenders() async throws {
        let offerings = PurchasableOfferings(
            monthly: PurchasableProduct(id: StoreProduct.monthlySubId, displayPrice: "€4.99", displayName: "Hangs Unlimited"),
            annual: nil,
            pack: nil
        )
        let manager = await makeStoreManager(offerings: offerings, hasAttemptedLoad: true)
        let view = PaywallView(storeManager: manager, limitError: nil, onDismiss: {})
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "unlimited") }
        }
    }

    @Test("limitMessage includes questionsLimit from QuotaLimitError")
    func limitMessageIncludesCount() async throws {
        let offerings = PurchasableOfferings(
            monthly: PurchasableProduct(id: StoreProduct.monthlySubId, displayPrice: "€4.99", displayName: "Hangs Unlimited"),
            annual: nil,
            pack: nil
        )
        let manager = await makeStoreManager(offerings: offerings, hasAttemptedLoad: true)
        let limitError = makeLimitError(questionsLimit: 10)
        let view = PaywallView(storeManager: manager, limitError: limitError, onDismiss: {})
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "You've used all 10 free questions this month.")
            }
        }
    }

    @Test("Countdown pill renders when limitError has a resetDate")
    func countdownPillRenders() async throws {
        let offerings = PurchasableOfferings(
            monthly: PurchasableProduct(id: StoreProduct.monthlySubId, displayPrice: "€4.99", displayName: "Hangs Unlimited"),
            annual: nil,
            pack: nil
        )
        let manager = await makeStoreManager(offerings: offerings, hasAttemptedLoad: true)
        let limitError = makeLimitError()
        let view = PaywallView(storeManager: manager, limitError: limitError, onDismiss: {})
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            // The countdown pill wraps an identifier — look for the "reset in" prefix text
            #expect(throws: Never.self) {
                try tree.findAll(ViewType.Text.self).first(where: {
                    (try? $0.string().contains("reset in")) == true
                }).map { _ in () } ?? { throw InspectionError.notSupported("No countdown text found") }()
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

    @Test("'OUT OF QUESTIONS' headline absent in offline variant")
    func paywallHeadlineAbsentWhenOffline() async throws {
        let manager = await makeStoreManager(offerings: nil, hasAttemptedLoad: true)
        let view = PaywallView(storeManager: manager, limitError: nil, onDismiss: {})
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) { try tree.find(text: "OUT OF\nQUESTIONS") }
        }
    }

    @Test("Feature card absent in offline variant")
    func featureCardAbsentWhenOffline() async throws {
        let manager = await makeStoreManager(offerings: nil, hasAttemptedLoad: true)
        let view = PaywallView(storeManager: manager, limitError: nil, onDismiss: {})
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) { try tree.find(text: "unlimited") }
        }
    }
}
