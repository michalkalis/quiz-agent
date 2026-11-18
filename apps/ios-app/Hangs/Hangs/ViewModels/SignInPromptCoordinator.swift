//
//  SignInPromptCoordinator.swift
//  Hangs
//
//  When the contextual Sign in with Apple sheet (#58 §9) appears: after a
//  purchase (#217.4: Trubbo Plus, question credit or a custom pack), only for
//  a signed-out buyer, at most `SignInPromptGate`'s cap across all purchase
//  kinds, and never stacked on another screen: a purchase made while the
//  paywall, the order flow or a quiz is up waits until the app is back at
//  rest. Moved out of ContentView in #194 A1.
//

import Combine
import Foundation

@MainActor
final class SignInPromptCoordinator: ObservableObject {
    /// The purchase the sheet is showing; nil while it is closed.
    @Published var presented: SignInPromptPurchase?

    private var pending: SignInPromptPurchase?
    /// The kind on screen whose outcome is not recorded yet.
    private var unrecordedKind: SignInPromptKind?
    private let tokenStore: any TokenStore
    private let persistenceStore: PersistenceStoreProtocol
    private let analytics: AnalyticsClient

    init(
        persistenceStore: PersistenceStoreProtocol,
        tokenStore: any TokenStore = KeychainTokenStore(),
        analytics: AnalyticsClient = NoopAnalyticsClient(),
        presented: SignInPromptPurchase? = nil
    ) {
        self.persistenceStore = persistenceStore
        self.tokenStore = tokenStore
        self.analytics = analytics
        self.presented = presented
    }

    private var isSignedIn: Bool {
        tokenStore.load()?.isSignedIn ?? false
    }

    /// A purchase went through. StoreManager re-checks Plus on every launch,
    /// so `.plus` also arrives on later app opens: the gate's shown-count cap
    /// (1 prompt + 1 reminder, all kinds together) is what bounds it. A count
    /// is spent when the prompt is scheduled; a second purchase before a
    /// waiting prompt shows only replaces what it will show.
    /// `canPresentNow`: false while another screen is up; the prompt then
    /// waits for `presentPendingIfAny()`.
    func purchaseCompleted(_ purchase: SignInPromptPurchase, canPresentNow: Bool) {
        guard presented == nil else { return }
        if pending != nil {
            pending = purchase
            return
        }
        guard SignInPromptGate.shouldPrompt(
            isSignedIn: isSignedIn,
            shownCount: persistenceStore.signInPromptShownCount
        ) else { return }
        persistenceStore.incrementSignInPromptShownCount()
        if canPresentNow {
            present(purchase)
        } else {
            pending = purchase
        }
    }

    /// The app is back at rest (no paywall, order flow or quiz on screen).
    /// A player who signed in elsewhere meanwhile has nothing left to link.
    func presentPendingIfAny() {
        guard let pending else { return }
        self.pending = nil
        guard !isSignedIn else { return }
        present(pending)
    }

    /// The sheet's own buttons: signed in, or "Maybe later".
    func finish(_ outcome: SignInPromptOutcome) {
        record(outcome)
        presented = nil
    }

    /// The sheet went away; a swipe down never went through `finish`.
    func sheetDismissed() {
        record(.dismissed)
    }

    private func present(_ purchase: SignInPromptPurchase) {
        presented = purchase
        unrecordedKind = purchase.analyticsKind
        analytics.track(.signInPromptShown(kind: purchase.analyticsKind))
    }

    private func record(_ outcome: SignInPromptOutcome) {
        guard let kind = unrecordedKind else { return }
        unrecordedKind = nil
        analytics.track(.signInPromptResult(kind: kind, outcome: outcome))
    }
}
