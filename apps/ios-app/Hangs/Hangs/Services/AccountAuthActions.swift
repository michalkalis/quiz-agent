//
//  AccountAuthActions.swift
//  Hangs
//
//  The account operations the Settings account section drives (#61), as a
//  protocol so `AccountSettingsModel` can be tested without the network.
//

import Foundation

nonisolated protocol AccountAuthActions: Sendable {
    func generateRawNonce() -> String
    func hashedNonce(for rawNonce: String) -> String
    func completeAppleSignIn(
        identityToken: String,
        authorizationCode: String,
        rawNonce: String,
        user: String,
        fullName: String?,
        email: String?
    ) async -> AuthTokens?
    func signOut() async
    func deleteAccount() async throws
    func exportData() async throws -> Data
}

extension AuthService: AccountAuthActions {}
