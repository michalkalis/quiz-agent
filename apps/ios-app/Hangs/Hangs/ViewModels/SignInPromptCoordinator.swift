//
//  SignInPromptCoordinator.swift
//  Hangs
//
//  When the contextual Sign in with Apple sheet (#58 §9) appears once Premium
//  is on: only for a signed-out buyer, at most `SignInPromptGate`'s cap, and
//  never stacked on the paywall — a purchase made from the paywall queues the
//  prompt until the paywall is dismissed. Moved out of ContentView in #194 A1.
//

import Combine
import Foundation

@MainActor
final class SignInPromptCoordinator: ObservableObject {
    @Published var isPresented: Bool

    private var isPendingAfterPaywall = false
    private let tokenStore: any TokenStore
    private let persistenceStore: PersistenceStoreProtocol

    init(
        persistenceStore: PersistenceStoreProtocol,
        tokenStore: any TokenStore = KeychainTokenStore(),
        isPresented: Bool = false
    ) {
        self.persistenceStore = persistenceStore
        self.tokenStore = tokenStore
        self.isPresented = isPresented
    }

    /// Premium turned on. StoreManager re-checks entitlements on every launch,
    /// so this fires at the purchase moment and on later app opens — the gate's
    /// shown-count cap (1 prompt + 1 reminder) is what bounds it.
    /// `whilePaywallShown`: present after the paywall closes, not on top of it.
    func premiumActivated(whilePaywallShown: Bool) {
        let isSignedIn = tokenStore.load()?.isSignedIn ?? false
        guard SignInPromptGate.shouldPrompt(
            isPurchased: true,
            isSignedIn: isSignedIn,
            shownCount: persistenceStore.signInPromptShownCount
        ) else { return }
        persistenceStore.incrementSignInPromptShownCount()
        if whilePaywallShown {
            isPendingAfterPaywall = true
        } else {
            isPresented = true
        }
    }

    func paywallDismissed() {
        guard isPendingAfterPaywall else { return }
        isPendingAfterPaywall = false
        isPresented = true
    }
}
