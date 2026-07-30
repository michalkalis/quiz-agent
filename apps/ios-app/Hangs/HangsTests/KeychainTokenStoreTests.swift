//
//  KeychainTokenStoreTests.swift
//  HangsTests
//
//  `KeychainTokenStore` is the only durable home of the identity every paid
//  entitlement hangs off (the JWT `sub` is the account purchases land on, #96
//  P1) — and it had zero tests (#133 audit named gap). It also swallows every
//  Keychain failure into a log line and a `nil`/no-op return, so a broken store
//  cannot announce itself: it just looks like a brand-new anonymous user, which
//  is exactly how a paying customer loses their subscription. These tests pin
//  the round-trip AND the swallow contract, so the "returns nil" behaviour is a
//  decision on record rather than an accident.
//
//  The type hard-wires its own Keychain coordinates (private `service`/
//  `account`, no injection seam), so this exercises the REAL Keychain in the
//  simulator — which works under normal signing. Do NOT run these with
//  `CODE_SIGNING_ALLOWED=NO`: the sim Keychain then fails with -34018 and every
//  test here degrades into the swallowed-error path (recorded trap, #113).
//
//  `.serialized` because the Keychain is process-wide shared state: the store's
//  item is one fixed generic-password entry, so two of these tests running
//  concurrently would fight over it.
//

import Foundation
@testable import Hangs
import Security
import Testing

@Suite("KeychainTokenStore (#133 named gap)", .serialized)
struct KeychainTokenStoreTests {
    private func makeTokens(
        access: String = "access-1",
        refresh: String = "refresh-1",
        anonId: String = "anon-1"
    ) -> AuthTokens {
        AuthTokens(accessToken: access, refreshToken: refresh, anonId: anonId)
    }

    /// The store's own coordinates, mirrored so a test can corrupt the stored
    /// blob the way a real Keychain/OS-level problem would. `SecItemUpdate`'s
    /// status is asserted at the call site, so if the production coordinates
    /// ever change this fails loudly instead of silently testing nothing.
    private var itemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(Bundle.main.bundleIdentifier ?? "com.missinghue.hangs").auth",
            kSecAttrAccount as String: "anon_tokens",
        ]
    }

    @Test("save → load round-trips the whole token pair, including the Apple account fields")
    func roundTripsTokens() {
        let store = KeychainTokenStore()
        store.clear()
        defer { store.clear() }

        let tokens = AuthTokens(
            accessToken: "access-abc",
            refreshToken: "refresh-def",
            anonId: "user-123",
            accountName: "Test Driver",
            accountEmail: "relay@privaterelay.appleid.com",
            appleUserId: "apple-sub-999"
        )
        store.save(tokens)

        // Equality over the whole struct: a partial round-trip (e.g. dropping
        // `appleUserId`) would silently demote a signed-in user to anonymous on
        // the next cold launch, and with them their subscription.
        #expect(store.load() == tokens)
        #expect(store.load()?.isSignedIn == true, "an Apple-backed pair must still read as signed in after a reload")
    }

    @Test("a second save overwrites the stored pair rather than leaving the old one")
    func saveUpsertsInsteadOfDuplicating() {
        let store = KeychainTokenStore()
        store.clear()
        defer { store.clear() }

        store.save(makeTokens(access: "old", refresh: "old-refresh", anonId: "anon-old"))
        store.save(makeTokens(access: "new", refresh: "new-refresh", anonId: "anon-new"))

        // The add path fails with errSecDuplicateItem once an item exists, so
        // without the update-first upsert a refresh would keep handing back the
        // stale (already-rejected) token pair forever.
        #expect(store.load()?.accessToken == "new")
        #expect(store.load()?.anonId == "anon-new")
    }

    @Test("clear() deletes the pair, and clearing again is a silent no-op")
    func clearDeletesAndIsIdempotent() {
        let store = KeychainTokenStore()
        store.save(makeTokens())
        #expect(store.load() != nil, "precondition: something is stored")

        store.clear()
        #expect(store.load() == nil, "sign-out must leave no token pair behind")

        // Sign-out paths call clear() unconditionally; errSecItemNotFound is the
        // normal case there and must not surface as a failure to the caller.
        store.clear()
        #expect(store.load() == nil)
    }

    @Test("load() returns nil for an unreadable blob — the documented swallow contract")
    func loadSwallowsUndecodableBlob() {
        let store = KeychainTokenStore()
        store.clear()
        defer { store.clear() }

        store.save(makeTokens())
        #expect(store.load() != nil, "precondition: a decodable pair is stored")

        // Corrupt the item in place (an interrupted write, a schema change, a
        // Keychain migration). Asserted status = this test breaks loudly if the
        // production service/account coordinates drift away from `itemQuery`.
        let corruptStatus = SecItemUpdate(
            itemQuery as CFDictionary,
            [kSecValueData as String: Data("not json".utf8)] as CFDictionary
        )
        #expect(corruptStatus == errSecSuccess, "the mirrored Keychain coordinates no longer match KeychainTokenStore")

        #expect(
            store.load() == nil,
            "an undecodable blob must read as 'no tokens' (the caller then re-bootstraps) — never crash or return a half-built pair"
        )

        // And the store must be recoverable: the next save has to succeed over
        // the corrupt item, or a user would be stuck anonymous forever.
        let fresh = makeTokens(access: "recovered", refresh: "recovered-refresh", anonId: "anon-recovered")
        store.save(fresh)
        #expect(store.load() == fresh, "a save over a corrupt item must repair the store")
    }
}
