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
        VStack(spacing: 0) {
            badge
                .padding(.top, 28)

            heroBlock
                .padding(.top, 20)

            if phase == .failed {
                errorBanner
                    .padding(.top, 16)
            }

            actionStack
                .padding(.top, phase == .failed ? 16 : 28)

            Spacer(minLength: 0)

            privacyNote
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Hangs.Colors.bgCard.ignoresSafeArea())
        .accessibilityIdentifier("signInPrompt.root")
    }

    // MARK: - Blocks

    private var badge: some View {
        ZStack {
            Circle()
                .fill(Theme.Hangs.Colors.accentPrimarySoft)
                .frame(width: 64, height: 64)
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 30, weight: .medium))
                .foregroundColor(Theme.Hangs.Colors.accentPrimary)
        }
        .accessibilityHidden(true)
        .accessibilityIdentifier("signInPrompt.badge")
    }

    private var heroBlock: some View {
        VStack(spacing: 10) {
            Text("KEEP YOUR PURCHASE")
                .font(.hangsDisplaySM)
                .foregroundColor(Theme.Hangs.Colors.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("signInPrompt.title")

            Text("Signing in links Premium to your Apple account — it stays with you on a new phone or after reinstalling.")
                .font(.hangsBody(15))
                .foregroundColor(Theme.Hangs.Colors.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("signInPrompt.subtitle")
        }
    }

    private var errorBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundColor(Theme.Hangs.Colors.error)
                .accessibilityHidden(true)
            Text("Sign-in didn't work. Check your connection and try again — your purchase is still saved on this device.")
                .font(.hangsBody(13))
                .foregroundColor(Theme.Hangs.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.Hangs.Colors.errorDim)
        )
        .accessibilityIdentifier("signInPrompt.errorBanner")
    }

    private var actionStack: some View {
        VStack(spacing: 12) {
            if phase == .signingIn {
                signingInIndicator
            } else {
                appleButton
            }

            HangsGhostButton(
                title: phase == .failed
                    ? "Later — I'll sign in from Settings"
                    : "Maybe later",
                color: Theme.Hangs.Colors.muted,
                font: .hangsBody(15, weight: .medium)
            ) {
                onDismiss()
            }
            .frame(height: 44)
            .disabled(phase == .signingIn)
            .accessibilityIdentifier("signInPrompt.later")
        }
    }

    private var appleButton: some View {
        SignInWithAppleButton(.signIn) { request in
            let rawNonce = authService.generateRawNonce()
            pendingRawNonce = rawNonce
            request.requestedScopes = [.fullName, .email]
            request.nonce = authService.hashedNonce(for: rawNonce)
        } onCompletion: { result in
            handleAppleSignInResult(result)
        }
        .signInWithAppleButtonStyle(.black)
        .frame(height: 54)
        .accessibilityIdentifier("signInPrompt.appleButton")
    }

    /// Mirrors the SIWA button's footprint while completeAppleSignIn runs,
    /// so the sheet doesn't jump between states.
    private var signingInIndicator: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(.white)
            Text("Signing in…")
                .font(.hangsBody(17, weight: .semibold))
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 54)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black)
        )
        .accessibilityIdentifier("signInPrompt.signingIn")
    }

    private var privacyNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock")
                .font(.system(size: 11))
                .accessibilityHidden(true)
            Text("We only use your name and email. No tracking.")
                .font(.hangsBody(12))
        }
        .foregroundColor(Theme.Hangs.Colors.textTertiary)
        .accessibilityIdentifier("signInPrompt.privacyNote")
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
