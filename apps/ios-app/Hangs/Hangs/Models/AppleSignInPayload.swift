//
//  AppleSignInPayload.swift
//  Hangs
//
//  Credential fields extracted from a completed Sign in with Apple
//  authorization. Shared by SettingsView (#61) and ContextualSignInSheet
//  (#58 §9) so both flows feed AuthService.completeAppleSignIn identically.
//

import AuthenticationServices

struct AppleSignInPayload {
    let identityToken: String
    let authorizationCode: String
    let user: String
    let fullName: String?
    let email: String?

    /// Fails when the credential is not an Apple ID credential or the
    /// identity token / authorization code are missing — callers treat
    /// that as a failed sign-in, never a crash.
    init?(authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let idTokenData = credential.identityToken,
              let idToken = String(data: idTokenData, encoding: .utf8),
              let authCodeData = credential.authorizationCode,
              let authCode = String(data: authCodeData, encoding: .utf8) else {
            return nil
        }
        identityToken = idToken
        authorizationCode = authCode
        user = credential.user
        let components = credential.fullName
        let joinedName = [components?.givenName, components?.familyName]
            .compactMap { $0 }
            .joined(separator: " ")
        fullName = joinedName.isEmpty ? nil : joinedName
        email = credential.email
    }
}
