//
//  ContextualSignInSheetTests.swift
//  HangsTests
//
//  #58 §9 — contextual sign-in prompt (decision 10, Variant B).
//
//  Why these tests matter:
//  - The gate encodes the founder-approved frequency contract: the sheet may
//    appear only after a purchase (#217.4: Plus, credit or a custom pack),
//    only for signed-out users, and at most twice ever across all kinds
//    (once at purchase + one reminder on a later open). Breaking
//    it either nags paying users or silently kills the account-linking
//    funnel — both are product regressions, not cosmetics.
//  - The sheet's three phases carry distinct driving-safe affordances:
//    idle = SIWA + "Maybe later", signing-in = no second tap possible,
//    failed = reassurance ("purchase still saved") + a named escape to
//    Settings. Losing any of these breaks the approved decision-10 states.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

// MARK: - SignInPromptGate (frequency contract)

@Suite("SignInPromptGate — decision 10 frequency contract")
@MainActor
struct SignInPromptGateTests {
    @Test("Never prompts a signed-in user — nothing left to link")
    func noPromptWhenSignedIn() {
        #expect(!SignInPromptGate.shouldPrompt(isSignedIn: true, shownCount: 0))
    }

    @Test("Prompts a signed-out buyer at the purchase moment (first presentation)")
    func promptsFirstTime() {
        #expect(SignInPromptGate.shouldPrompt(isSignedIn: false, shownCount: 0))
    }

    @Test("Allows exactly one reminder on a later app open")
    func allowsSingleReminder() {
        #expect(SignInPromptGate.shouldPrompt(isSignedIn: false, shownCount: 1))
    }

    @Test("Never self-presents after the reminder — Profile keeps the permanent entry")
    func stopsAfterReminder() {
        #expect(!SignInPromptGate.shouldPrompt(isSignedIn: false, shownCount: 2))
        #expect(!SignInPromptGate.shouldPrompt(isSignedIn: false, shownCount: 5))
    }
}

// MARK: - Persistence of the shown-count

@Suite("PersistenceStore — sign-in prompt count survives")
@MainActor
struct SignInPromptPersistenceTests {
    @Test("Count starts at 0 and increments durably — the 2-cap depends on it")
    func countIncrements() {
        let defaults = UserDefaults(suiteName: "signInPromptTests-\(UUID().uuidString)")!
        let store = PersistenceStore(userDefaults: defaults)
        #expect(store.signInPromptShownCount == 0)
        store.incrementSignInPromptShownCount()
        store.incrementSignInPromptShownCount()
        #expect(store.signInPromptShownCount == 2)
    }
}

// MARK: - Sheet structure per phase

@MainActor
private func makeSheet(
    phase: ContextualSignInSheet.Phase,
    purchase: SignInPromptPurchase = .plus
) -> ContextualSignInSheet {
    ContextualSignInSheet(
        purchase: purchase,
        authService: AuthService(baseURL: Config.apiBaseURL),
        initialPhase: phase
    ) { _ in }
}

@Suite("ContextualSignInSheet — decision 10 states")
@MainActor
struct ContextualSignInSheetStateTests {
    @Test("Idle: purchase, value pitch, SIWA and Maybe later, no error banner")
    func idleStructure() throws {
        let tree = try makeSheet(phase: .idle).inspect()
        #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "signInPrompt.hero") }
        #expect(throws: Never.self) { try tree.find(text: "Save your Plus") }
        #expect(throws: Never.self) {
            try tree.find(viewWithAccessibilityIdentifier: "signInPrompt.appleButton")
        }
        #expect(throws: Never.self) { try tree.find(text: "Maybe later") }
        #expect(throws: (any Error).self) {
            try tree.find(viewWithAccessibilityIdentifier: "signInPrompt.errorBanner")
        }
    }

    @Test("Signing in: progress indicator replaces SIWA so no second tap is possible")
    func signingInStructure() throws {
        let tree = try makeSheet(phase: .signingIn).inspect()
        #expect(throws: Never.self) {
            try tree.find(viewWithAccessibilityIdentifier: "signInPrompt.signingIn")
        }
        #expect(throws: (any Error).self) {
            try tree.find(viewWithAccessibilityIdentifier: "signInPrompt.appleButton")
        }
    }

    @Test("Failed: reassuring banner + retry via SIWA + named escape to Settings")
    func failedStructure() throws {
        let tree = try makeSheet(phase: .failed).inspect()
        #expect(throws: Never.self) {
            try tree.find(viewWithAccessibilityIdentifier: "signInPrompt.errorBanner")
        }
        // Retry happens on the same SIWA button — it must stay present.
        #expect(throws: Never.self) {
            try tree.find(viewWithAccessibilityIdentifier: "signInPrompt.appleButton")
        }
        #expect(throws: Never.self) { try tree.find(text: "Later, I'll sign in from Settings") }
    }
}

// MARK: - What was bought (#217.4)

/// #217.4 (founder 2026-11-04): the prompt names exactly what the player just
/// bought. A credit or pack buyer told "Trubbo Plus stays with you" would be
/// promised the wrong thing, and a pack shown in another colour or with a
/// made-up count would not read as the pack they ordered.
@Suite("ContextualSignInSheet — shows what was bought")
@MainActor
struct ContextualSignInSheetPurchaseTests {
    @Test("Plus: Plus title and the Plus promise")
    func plus() throws {
        let tree = try makeSheet(phase: .idle, purchase: .plus).inspect()
        #expect(throws: Never.self) { try tree.find(text: "Save your Plus") }
        #expect(throws: Never.self) {
            try tree.find(text: "Signing in links Trubbo Plus to your Apple account, so it stays with you on a new phone or after reinstalling.")
        }
        #expect(throws: Never.self) { try tree.find(text: "Trubbo Plus") }
    }

    @Test("Credit: the purchased count on the card, the credit promise")
    func credit() throws {
        let tree = try makeSheet(phase: .idle, purchase: .credit(questionCount: 100)).inspect()
        #expect(throws: Never.self) { try tree.find(text: "Save your credit") }
        #expect(throws: Never.self) { try tree.find(text: "+100") }
        #expect(throws: Never.self) {
            try tree.find(text: "Your credit is only on this phone for now. Sign in with Apple and it stays with you on a new phone or after reinstalling.")
        }
        #expect(throws: (any Error).self) { try tree.find(text: "Trubbo Plus") }
    }

    @Test("Custom pack: its name and real count, the pack promise")
    func customPack() throws {
        let purchase = SignInPromptPurchase.customPack(name: "Harry Potter", questionCount: 30, colorKey: "order-1")
        let tree = try makeSheet(phase: .idle, purchase: purchase).inspect()
        #expect(throws: Never.self) { try tree.find(text: "Save your pack") }
        #expect(throws: Never.self) { try tree.find(text: "Harry Potter") }
        #expect(throws: Never.self) {
            try tree.find(text: "Your pack is only on this phone for now. Sign in with Apple and it stays with you on a new phone or after reinstalling.")
        }
    }

    @Test("Analytics kind per purchase — the prompt funnel is sliced by it")
    func analyticsKind() {
        #expect(SignInPromptPurchase.plus.analyticsKind == .plus)
        #expect(SignInPromptPurchase.credit(questionCount: 100).analyticsKind == .credit)
        #expect(SignInPromptPurchase.customPack(name: "x", questionCount: 30, colorKey: "k").analyticsKind == .customPack)
    }

    /// The credit pack never flips `isPurchased`, so its purchase outcome is
    /// the only signal. `.activating` is a real purchase (money moved), a
    /// restore (nil product) or a Plus purchase is not a credit purchase.
    @Test("Only a finished credit purchase maps to the credit prompt")
    func creditFromPurchaseState() {
        let credit = SignInPromptPurchase.credit(questionCount: StoreProduct.packQuestionCount)
        #expect(SignInPromptPurchase.credit(after: .success(productID: StoreProduct.packId)) == credit)
        #expect(SignInPromptPurchase.credit(after: .activating(productID: StoreProduct.packId)) == credit)
        #expect(SignInPromptPurchase.credit(after: .success(productID: StoreProduct.monthlySubId)) == nil)
        #expect(SignInPromptPurchase.credit(after: .success(productID: nil)) == nil)
        #expect(SignInPromptPurchase.credit(after: .purchasing(productID: StoreProduct.packId)) == nil)
        #expect(SignInPromptPurchase.credit(after: .cancelled) == nil)
        #expect(SignInPromptPurchase.credit(after: .failed(message: "x")) == nil)
    }
}
