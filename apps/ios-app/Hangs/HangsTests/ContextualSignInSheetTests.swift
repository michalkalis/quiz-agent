//
//  ContextualSignInSheetTests.swift
//  HangsTests
//
//  #58 §9 — contextual sign-in prompt (decision 10, Variant B).
//
//  Why these tests matter:
//  - The gate encodes the founder-approved frequency contract: the sheet may
//    appear only after Premium is on, only for signed-out users, and at most
//    twice ever (once at purchase + one reminder on a later open). Breaking
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
    @Test("Never prompts before Premium is on — Variant B forbids pre-purchase friction")
    func noPromptWithoutPurchase() {
        #expect(!SignInPromptGate.shouldPrompt(isPurchased: false, isSignedIn: false, shownCount: 0))
    }

    @Test("Never prompts a signed-in user — nothing left to link")
    func noPromptWhenSignedIn() {
        #expect(!SignInPromptGate.shouldPrompt(isPurchased: true, isSignedIn: true, shownCount: 0))
    }

    @Test("Prompts at the purchase moment (first presentation)")
    func promptsFirstTime() {
        #expect(SignInPromptGate.shouldPrompt(isPurchased: true, isSignedIn: false, shownCount: 0))
    }

    @Test("Allows exactly one reminder on a later app open")
    func allowsSingleReminder() {
        #expect(SignInPromptGate.shouldPrompt(isPurchased: true, isSignedIn: false, shownCount: 1))
    }

    @Test("Never self-presents after the reminder — Settings keeps the permanent entry")
    func stopsAfterReminder() {
        #expect(!SignInPromptGate.shouldPrompt(isPurchased: true, isSignedIn: false, shownCount: 2))
        #expect(!SignInPromptGate.shouldPrompt(isPurchased: true, isSignedIn: false, shownCount: 5))
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
private func makeSheet(phase: ContextualSignInSheet.Phase) -> ContextualSignInSheet {
    ContextualSignInSheet(
        authService: AuthService(baseURL: Config.apiBaseURL),
        initialPhase: phase
    ) {}
}

@Suite("ContextualSignInSheet — decision 10 states")
@MainActor
struct ContextualSignInSheetStateTests {
    @Test("Idle: value pitch + SIWA + Maybe later + privacy note, no error banner")
    func idleStructure() throws {
        let tree = try makeSheet(phase: .idle).inspect()
        #expect(throws: Never.self) { try tree.find(text: "KEEP YOUR PURCHASE") }
        #expect(throws: Never.self) {
            try tree.find(viewWithAccessibilityIdentifier: "signInPrompt.appleButton")
        }
        #expect(throws: Never.self) { try tree.find(text: "Maybe later") }
        #expect(throws: Never.self) {
            try tree.find(viewWithAccessibilityIdentifier: "signInPrompt.privacyNote")
        }
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
        #expect(throws: Never.self) { try tree.find(text: "Later — I'll sign in from Settings") }
    }
}
