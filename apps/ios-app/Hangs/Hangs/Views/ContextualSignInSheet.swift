//
//  ContextualSignInSheet.swift
//  Hangs
//
//  #58 §9 — contextual sign-in prompt (decision 10, Variant B): a bottom
//  sheet offered at the moment Premium turns on (purchase or restore),
//  linking the purchase to the user's Apple account. Matches Pencil
//  Auth/Contextual-SignIn (WAIEy). Zero friction before payment — the
//  sheet never appears pre-purchase; Settings keeps the permanent entry.
//

import AuthenticationServices
import SwiftUI

/// Decides when the contextual sign-in sheet may appear (decision 10):
/// once right after purchase, at most one reminder on a later app open,
/// then never again on its own.
enum SignInPromptGate {
    /// 1 post-purchase presentation + 1 reminder — founder-approved cap.
    static let maxPresentations = 2

    static func shouldPrompt(isPurchased: Bool, isSignedIn: Bool, shownCount: Int) -> Bool {
        isPurchased && !isSignedIn && shownCount < maxPresentations
    }
}

struct ContextualSignInSheet: View {
    let authService: AuthService
    /// Called on successful sign-in and on "Maybe later".
    let onDismiss: () -> Void

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

    init(authService: AuthService, initialPhase: Phase = .idle, onDismiss: @escaping () -> Void) {
        self.authService = authService
        self.onDismiss = onDismiss
        _phase = State(initialValue: initialPhase)
    }

    var body: some View {
        // #194 C7 (canvas Bg-SignIn): left-aligned sheet, cobalt badge, capsule
        // Apple button, glass "Maybe later".
        VStack(alignment: .leading, spacing: 0) {
            badge
                .padding(.top, Theme.Hangs.Spacing.xl)

            heroBlock
                .padding(.top, Theme.Hangs.Spacing.md)

            if phase == .failed {
                errorBanner
                    .padding(.top, Theme.Hangs.Spacing.md)
            }

            actionStack
                .padding(.top, Theme.Hangs.Spacing.lg)

            Spacer(minLength: Theme.Hangs.Spacing.md)

            privacyNote
                .padding(.bottom, Theme.Hangs.Spacing.sm)
        }
        .padding(.horizontal, Theme.Hangs.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Hangs.Colors.bgSheet.ignoresSafeArea())
        .accessibilityIdentifier("signInPrompt.root")
    }

    // MARK: - Blocks

    private var badge: some View {
        Image(systemName: "checkmark.seal.fill")
            .font(.hangsHeading)
            .foregroundStyle(Theme.Hangs.Colors.textOnAccent)
            .frame(width: Metrics.badge, height: Metrics.badge)
            .background(Circle().fill(Theme.Hangs.Colors.accentPrimary))
            .accessibilityHidden(true)
            .accessibilityIdentifier("signInPrompt.badge")
    }

    private var heroBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xs) {
            Text("KEEP YOUR PURCHASE")
                .font(.hangsTitle)
                .foregroundStyle(Theme.Hangs.Colors.ink)
                .hangsHeadlineFit()
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("signInPrompt.title")

            Text("Signing in links Premium to your Apple account — it stays with you on a new phone or after reinstalling.")
                .font(.hangsBodyLG)
                .foregroundStyle(Theme.Hangs.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("signInPrompt.subtitle")
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
        VStack(spacing: Theme.Hangs.Spacing.sm) {
            if phase == .signingIn {
                signingInIndicator
            } else {
                appleButton
            }

            HangsSecondaryButton(
                title: phase == .failed
                    ? "Later — I'll sign in from Settings"
                    : "Maybe later",
                height: Metrics.buttonHeight
            ) {
                onDismiss()
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

    private var privacyNote: some View {
        Label {
            Text("Keeps your purchases and progress across devices. Nothing else is shared.")
                .font(.hangsCaption)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lock")
                .font(.hangsCaption)
                .accessibilityHidden(true)
        }
        .foregroundStyle(Theme.Hangs.Colors.muted)
        .accessibilityIdentifier("signInPrompt.privacyNote")
    }

    private enum Metrics {
        static let badge: CGFloat = 60
        static let errorDisc: CGFloat = 30
        static let buttonHeight: CGFloat = 56
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
                    onDismiss()
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
    ContextualSignInSheet(authService: AuthService(baseURL: Config.apiBaseURL)) {}
}
#endif
