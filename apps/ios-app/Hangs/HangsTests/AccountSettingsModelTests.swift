//
//  AccountSettingsModelTests.swift
//  HangsTests
//
//  #194 A1: the Settings account section's logic moved out of SettingsView
//  into AccountSettingsModel. These pin what the view used to do inline so the
//  redesign can restyle the section without regressing sign-in, sign-out,
//  delete or export.
//

import AuthenticationServices
import Foundation
@testable import Hangs
import os
import Testing

private nonisolated final class StubTokenStore: TokenStore, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<AuthTokens?>(initialState: nil)

    func load() -> AuthTokens? { lock.withLock { $0 } }
    func save(_ tokens: AuthTokens) { lock.withLock { $0 = tokens } }
    func clear() { lock.withLock { $0 = nil } }
}

private nonisolated final class StubAccountAuth: AccountAuthActions, @unchecked Sendable {
    struct SignInCall: Equatable, Sendable {
        let identityToken: String
        let rawNonce: String
        let user: String
    }

    let store: StubTokenStore
    private let lock = OSAllocatedUnfairLock(initialState: State())

    struct State: Sendable {
        var signInCalls: [SignInCall] = []
        var signInResult: AuthTokens?
        var deleteFails = false
        /// nil = the export request fails.
        var exportBody: Data? = Data()
    }

    init(store: StubTokenStore) {
        self.store = store
    }

    var signInCalls: [SignInCall] { lock.withLock { $0.signInCalls } }
    func setSignInResult(_ tokens: AuthTokens?) { lock.withLock { $0.signInResult = tokens } }
    func setDeleteFails() { lock.withLock { $0.deleteFails = true } }
    func setExportBody(_ body: Data?) { lock.withLock { $0.exportBody = body } }

    func generateRawNonce() -> String { "raw-nonce-1" }
    func hashedNonce(for rawNonce: String) -> String { "hashed(\(rawNonce))" }

    func completeAppleSignIn(
        identityToken: String,
        authorizationCode _: String,
        rawNonce: String,
        user: String,
        fullName _: String?,
        email _: String?
    ) async -> AuthTokens? {
        let result = lock.withLock { state in
            state.signInCalls.append(SignInCall(identityToken: identityToken, rawNonce: rawNonce, user: user))
            return state.signInResult
        }
        if let result { store.save(result) }
        return result
    }

    func signOut() async {
        store.save(AuthTokens(accessToken: "anon-a", refreshToken: "anon-r", anonId: "anon-2"))
    }

    func deleteAccount() async throws {
        if lock.withLock({ $0.deleteFails }) { throw DeleteFailed() }
        store.save(AuthTokens(accessToken: "anon-a", refreshToken: "anon-r", anonId: "anon-3"))
    }

    func exportData() async throws -> Data {
        guard let body = lock.withLock({ $0.exportBody }) else { throw DeleteFailed() }
        return body
    }
}

private nonisolated struct DeleteFailed: LocalizedError {
    var errorDescription: String? { "server said no" }
}

private let signedIn = AuthTokens(
    accessToken: "acc", refreshToken: "ref", anonId: "user-1",
    accountName: nil, accountEmail: nil, appleUserId: "apple-1"
)

private let payload = AppleSignInPayload(
    identityToken: "id-token", authorizationCode: "code", user: "apple-1", fullName: nil, email: nil
)

@Suite("Settings account section logic (#194 A1)")
@MainActor
struct AccountSettingsModelTests {
    /// WHY: Apple verifies the id_token against the HASHED nonce on the request,
    /// the backend against the RAW one. A swapped or regenerated nonce rejects
    /// every sign-in.
    @Test("the request carries the hashed nonce and completion sends the same raw nonce")
    func nonceRoundTrip() async {
        let store = StubTokenStore()
        let auth = StubAccountAuth(store: store)
        let model = AccountSettingsModel(tokenStore: store, presentShareSheet: { _ in })
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.email, .fullName]

        model.prepareSignInRequest(request, auth: auth)

        #expect(request.nonce == "hashed(raw-nonce-1)")
        #expect(request.requestedScopes?.isEmpty == true, "Settings asks for no name/email scopes")

        await model.completeSignIn(payload, auth: auth).value
        #expect(auth.signInCalls == [.init(identityToken: "id-token", rawNonce: "raw-nonce-1", user: "apple-1")])
    }

    /// WHY: the section switches to the signed-in layout from the Keychain
    /// state, and the button is disabled only while the exchange runs.
    @Test("a successful sign-in flips to signed-in and re-enables the button")
    func signInSuccess() async {
        let store = StubTokenStore()
        let auth = StubAccountAuth(store: store)
        auth.setSignInResult(signedIn)
        let model = AccountSettingsModel(tokenStore: store, presentShareSheet: { _ in })

        let task = model.completeSignIn(payload, auth: auth)
        #expect(model.isSigningIn)
        await task.value

        #expect(!model.isSigningIn)
        #expect(model.currentTokens?.isSignedIn == true)
    }

    @Test("a failed sign-in keeps the previous account state")
    func signInFailureKeepsState() async {
        let store = StubTokenStore()
        let anon = AuthTokens(accessToken: "a", refreshToken: "r", anonId: "anon-1")
        store.save(anon)
        let auth = StubAccountAuth(store: store)
        let model = AccountSettingsModel(tokenStore: store, presentShareSheet: { _ in })
        model.reloadTokens()
        store.save(signedIn) // a Keychain change the model must NOT pick up on a failed sign-in

        await model.completeSignIn(payload, auth: auth).value

        #expect(!model.isSigningIn)
        #expect(model.currentTokens?.anonId == "anon-1")
    }

    @Test("sign-out reloads the fresh anonymous identity")
    func signOutReloads() async {
        let store = StubTokenStore()
        store.save(signedIn)
        let auth = StubAccountAuth(store: store)
        let model = AccountSettingsModel(tokenStore: store, presentShareSheet: { _ in })
        model.reloadTokens()
        #expect(model.currentTokens?.isSignedIn == true)

        await model.signOut(auth: auth).value

        #expect(model.currentTokens?.isSignedIn == false)
        #expect(model.currentTokens?.anonId == "anon-2")
    }

    /// WHY: a failed deletion must be surfaced (App Store 5.1.1(v) — the user
    /// has to know their data was NOT removed), never swallowed.
    @Test("a failed delete surfaces the error and leaves the account in place")
    func deleteFailureSurfaces() async {
        let store = StubTokenStore()
        store.save(signedIn)
        let auth = StubAccountAuth(store: store)
        auth.setDeleteFails()
        let model = AccountSettingsModel(tokenStore: store, presentShareSheet: { _ in })
        model.reloadTokens()

        await model.deleteAccount(auth: auth).value

        #expect(model.errorMessage == "server said no")
        #expect(!model.isDeletingAccount)
        #expect(model.currentTokens?.isSignedIn == true)
    }

    @Test("a successful delete reloads the fresh identity without an error")
    func deleteSuccess() async {
        let store = StubTokenStore()
        store.save(signedIn)
        let auth = StubAccountAuth(store: store)
        let model = AccountSettingsModel(tokenStore: store, presentShareSheet: { _ in })
        model.reloadTokens()

        await model.deleteAccount(auth: auth).value

        #expect(model.errorMessage == nil)
        #expect(!model.isDeletingAccount)
        #expect(model.currentTokens?.anonId == "anon-3")
    }

    /// WHY: GDPR export hands the user a JSON file of exactly what the server
    /// returned; a failed export shows no share sheet.
    @Test("export writes the server payload to a JSON file and shares it")
    func exportShares() async throws {
        let store = StubTokenStore()
        let auth = StubAccountAuth(store: store)
        let body = Data(#"{"history":[]}"#.utf8)
        auth.setExportBody(body)
        var shared: [Any] = []
        let model = AccountSettingsModel(tokenStore: store, presentShareSheet: { shared = $0 })

        await model.exportData(auth: auth).value

        let url = try #require(shared.first as? URL)
        #expect(shared.count == 1)
        #expect(url.lastPathComponent == "my-data-export.json")
        #expect(try Data(contentsOf: url) == body)
    }

    @Test("a failed export presents nothing")
    func exportFailurePresentsNothing() async {
        let store = StubTokenStore()
        let auth = StubAccountAuth(store: store)
        auth.setExportBody(nil)
        var presented = false
        let model = AccountSettingsModel(tokenStore: store, presentShareSheet: { _ in presented = true })

        await model.exportData(auth: auth).value

        #expect(!presented)
    }
}
