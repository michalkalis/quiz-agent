//
//  AccountSettingsModel.swift
//  Hangs
//
//  State and actions behind the Settings account section (#61 task 61.7):
//  Sign in with Apple, sign out, delete account, data export. Moved out of
//  SettingsView in #194 A1 so the redesign only touches layout. The auth
//  service comes from AppState's environment, so each action takes it as an
//  argument; the model stays view-scoped like the `@State` it replaced.
//

import AuthenticationServices
import Combine
import Foundation
import os

@MainActor
final class AccountSettingsModel: ObservableObject {
    /// Mirrors the Keychain; reloaded on appear and after every auth event.
    @Published private(set) var currentTokens: AuthTokens?
    @Published private(set) var isSigningIn = false
    @Published private(set) var isDeletingAccount = false
    @Published var errorMessage: String?

    /// Raw nonce generated when the sign-in request is built, held across the
    /// `SignInWithAppleButton` onRequest → onCompletion lifecycle.
    private var pendingRawNonce = ""
    private let tokenStore: any TokenStore
    private let presentShareSheet: @MainActor ([Any]) -> Void

    init(
        tokenStore: any TokenStore = KeychainTokenStore(),
        presentShareSheet: @escaping @MainActor ([Any]) -> Void = ShareSheetPresenter.present
    ) {
        self.tokenStore = tokenStore
        self.presentShareSheet = presentShareSheet
    }

    func reloadTokens() {
        currentTokens = tokenStore.load()
    }

    func prepareSignInRequest(_ request: ASAuthorizationAppleIDRequest, auth: any AccountAuthActions) {
        let rawNonce = auth.generateRawNonce()
        pendingRawNonce = rawNonce
        request.requestedScopes = []
        request.nonce = auth.hashedNonce(for: rawNonce)
    }

    func handleSignInResult(_ result: Result<ASAuthorization, Error>, auth: any AccountAuthActions) {
        switch result {
        case let .success(authorization):
            guard let payload = AppleSignInPayload(authorization: authorization) else {
                Logger.network.warning("🔐 Apple sign-in: missing identity_token or authorization_code")
                return
            }
            completeSignIn(payload, auth: auth)
        case let .failure(error):
            // User cancelled or system error — not an app error; ASAuthorizationError.canceled is common.
            Logger.network.info("🔐 Apple sign-in cancelled/failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @discardableResult
    func completeSignIn(_ payload: AppleSignInPayload, auth: any AccountAuthActions) -> Task<Void, Never> {
        let rawNonce = pendingRawNonce
        isSigningIn = true
        return Task {
            let newTokens = await auth.completeAppleSignIn(
                identityToken: payload.identityToken,
                authorizationCode: payload.authorizationCode,
                rawNonce: rawNonce,
                user: payload.user,
                fullName: payload.fullName,
                email: payload.email
            )
            isSigningIn = false
            if newTokens != nil {
                reloadTokens()
            }
        }
    }

    @discardableResult
    func signOut(auth: any AccountAuthActions) -> Task<Void, Never> {
        Task {
            await auth.signOut()
            reloadTokens()
        }
    }

    @discardableResult
    func deleteAccount(auth: any AccountAuthActions) -> Task<Void, Never> {
        Task {
            isDeletingAccount = true
            do {
                try await auth.deleteAccount()
                reloadTokens()
            } catch {
                errorMessage = error.localizedDescription
            }
            isDeletingAccount = false
        }
    }

    /// Writes the export to a temp JSON file and hands it to the share sheet.
    @discardableResult
    func exportData(auth: any AccountAuthActions) -> Task<Void, Never> {
        Task {
            do {
                let data = try await auth.exportData()
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("my-data-export.json")
                try data.write(to: tempURL)
                presentShareSheet([tempURL])
            } catch {
                Logger.network.warning("🔐 Export data failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
