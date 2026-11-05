//
//  ContextualSignInSheet.swift
//  Hangs
//
//  #58 §9 — contextual sign-in prompt (decision 10, Variant B): a bottom
//  sheet offered right after a purchase (#217.4: Trubbo Plus, question credit
//  or a custom pack), linking it to the user's Apple account. Zero friction
//  before payment: the sheet never appears pre-purchase or on a fresh
//  install; Profile keeps the permanent entry.
//

import AuthenticationServices
import SwiftUI

/// Decides when the contextual sign-in sheet may appear (decision 10, #217.4):
/// after a purchase of any kind, at most twice ever across all kinds (the
/// purchase moment + one reminder), then never again on its own.
enum SignInPromptGate {
    /// 1 post-purchase presentation + 1 reminder — founder-approved cap.
    static let maxPresentations = 2

    static func shouldPrompt(isSignedIn: Bool, shownCount: Int) -> Bool {
        !isSignedIn && shownCount < maxPresentations
    }
}

struct ContextualSignInSheet: View {
    enum Phase {
        case idle
        case signingIn
        case failed
    }

    @State private var phase: Phase
    /// Raw nonce generated at sign-in tap time; held across the
    /// SignInWithAppleButton onRequest → onCompletion lifecycle (F6: the
    /// request carries base64url-nopad(SHA256(rawNonce))).
    @State private var pendingRawNonce = ""
    /// The content's height, which the sheet's detent follows so the sheet
    /// stays as low as its content at every text size.
    @State private var contentHeight = Metrics.initialHeight

    /// What was just bought; the sheet shows it and offers to keep it.
    let purchase: SignInPromptPurchase
    let authService: AuthService
    /// Called on successful sign-in and on "Maybe later".
    let onFinish: (SignInPromptOutcome) -> Void

    init(
        purchase: SignInPromptPurchase,
        authService: AuthService,
        initialPhase: Phase = .idle,
        onFinish: @escaping (SignInPromptOutcome) -> Void
    ) {
        self.purchase = purchase
        self.authService = authService
        self.onFinish = onFinish
        _phase = State(initialValue: initialPhase)
    }

    var body: some View {
        // #217.4 (canvas F-*): a low, left-aligned sheet: the purchase as a
        // tilted card, what signing in keeps, capsule Apple button, "Maybe later".
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SignInPromptHero(purchase: purchase)
                    .padding(.top, Theme.Hangs.Spacing.xxl)
                    .padding(.leading, Theme.Hangs.Spacing.xxs)

                heroBlock
                    .padding(.top, Theme.Hangs.Spacing.lg)

                if phase == .failed {
                    errorBanner
                        .padding(.top, Theme.Hangs.Spacing.md)
                }

                actionStack
                    .padding(.top, Theme.Hangs.Spacing.lg)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Hangs.Spacing.xl)
            .padding(.bottom, Theme.Hangs.Spacing.xs)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Hangs.Colors.bgSheet.ignoresSafeArea())
        .presentationDetents([.height(contentHeight)])
        .accessibilityIdentifier("signInPrompt.root")
    }

    // MARK: - Blocks

    private var heroBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xs) {
            Text(title)
                .font(.hangsTitle)
                .textCase(.uppercase)
                .foregroundStyle(Theme.Hangs.Colors.ink)
                .hangsHeadlineFit()
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("signInPrompt.title")

            Text(message)
                .font(.hangsBodyLG)
                .foregroundStyle(Theme.Hangs.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("signInPrompt.subtitle")
        }
    }

    private var title: LocalizedStringKey {
        switch purchase {
        case .plus: "Save your Plus"
        case .credit: "Save your credit"
        case .customPack: "Save your pack"
        }
    }

    private var message: LocalizedStringKey {
        switch purchase {
        case .plus: "Signing in links Trubbo Plus to your Apple account, so it stays with you on a new phone or after reinstalling."
        case .credit: "Your credit is only on this phone for now. Sign in with Apple and it stays with you on a new phone or after reinstalling."
        case .customPack: "Your pack is only on this phone for now. Sign in with Apple and it stays with you on a new phone or after reinstalling."
        }
    }

    private var errorBanner: some View {
        HStack(alignment: .top, spacing: Theme.Hangs.Spacing.sm) {
            Image(systemName: "exclamationmark")
                .font(.hangsCaption.weight(.bold))
                .foregroundStyle(Theme.Hangs.Category.style(for: "sports").text)
                .frame(width: Metrics.errorDisc, height: Metrics.errorDisc)
                .background(Circle().fill(Theme.Hangs.Category.style(for: "sports").fill))
                .accessibilityHidden(true)
            Text("Sign-in didn't work. Check your connection and try again — your purchase is still saved on this device.")
                .font(.hangsBody)
                .foregroundStyle(Theme.Hangs.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Hangs.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Hangs.Radius.card, style: .continuous)
                .fill(Theme.Hangs.Colors.bgCard)
                .strokeBorder(Theme.Hangs.Colors.subtleBorder)
        )
        .accessibilityIdentifier("signInPrompt.errorBanner")
    }

    private var actionStack: some View {
        VStack(spacing: Theme.Hangs.Spacing.xxs) {
            if phase == .signingIn {
                signingInIndicator
            } else {
                appleButton
            }

            HangsGhostButton(
                title: phase == .failed
                    ? "Later — I'll sign in from Settings"
                    : "Maybe later",
                color: Theme.Hangs.Colors.ink,
                font: .hangsButton
            ) {
                onFinish(.dismissed)
            }
            .disabled(phase == .signingIn)
            .accessibilityIdentifier("signInPrompt.later")
        }
    }

    private var appleButton: some View {
        SignInWithAppleButton(.signIn) { request in
            let rawNonce = authService.generateRawNonce()
            pendingRawNonce = rawNonce
            request.requestedScopes = []
            request.nonce = authService.hashedNonce(for: rawNonce)
        } onCompletion: { result in
            handleAppleSignInResult(result)
        }
        .signInWithAppleButtonStyle(.black)
        .frame(height: Metrics.buttonHeight)
        .clipShape(Capsule())
        .accessibilityIdentifier("signInPrompt.appleButton")
    }

    /// Mirrors the SIWA button's footprint while completeAppleSignIn runs,
    /// so the sheet doesn't jump between states.
    private var signingInIndicator: some View {
        HStack(spacing: Theme.Hangs.Spacing.xs) {
            ProgressView()
                .tint(Theme.Hangs.Colors.textOnAccent)
            Text("Signing in…")
                .font(.hangsLabel)
                .foregroundStyle(Theme.Hangs.Colors.textOnAccent)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Metrics.buttonHeight)
        .background(
            Capsule()
                .fill(Color.black) // design-token: mirrors Apple's black Sign in with Apple button
        )
        .accessibilityIdentifier("signInPrompt.signingIn")
    }

    private enum Metrics {
        /// The canvas sheet (F-*) at the default text size, until measured.
        static let initialHeight: CGFloat = 400
        static let errorDisc: CGFloat = 30
        static let buttonHeight: CGFloat = 52
    }

    // MARK: - Sign-in handling

    private func handleAppleSignInResult(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let payload = AppleSignInPayload(authorization: auth) else {
                phase = .failed
                return
            }
            phase = .signingIn
            let rawNonce = pendingRawNonce
            Task {
                let newTokens = await authService.completeAppleSignIn(
                    identityToken: payload.identityToken,
                    authorizationCode: payload.authorizationCode,
                    rawNonce: rawNonce,
                    user: payload.user,
                    fullName: payload.fullName,
                    email: payload.email
                )
                if newTokens != nil {
                    onFinish(.signedIn)
                } else {
                    phase = .failed
                }
            }
        case .failure(let error):
            // Cancelling the Apple dialog is a normal exit, not an error state.
            if let asError = error as? ASAuthorizationError, asError.code == .canceled {
                return
            }
            phase = .failed
        }
    }
}

#if DEBUG
#Preview {
    ContextualSignInSheet(
        purchase: .customPack(name: "Harry Potter", questionCount: 30, colorKey: "order-1"),
        authService: AuthService(baseURL: Config.apiBaseURL)
    ) { _ in }
}
#endif
