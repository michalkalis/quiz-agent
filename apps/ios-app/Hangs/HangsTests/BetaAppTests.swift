//
//  BetaAppTests.swift
//  HangsTests
//
//  #234 — Trubbo Beta: the TestFlight build is a second app on the same phone.
//  App Store product ids are unique across the developer account, so the beta
//  app sells `beta.` + the live id; a wrong id means StoreKit finds no product
//  and the beta paywall is empty. Universal links: two apps claiming one path
//  open either at random, so each app invites and joins on its own path.
//  The test host is Hangs-Local (no BETA condition), so the beta side runs
//  through the injected flag.
//

import Foundation
@testable import Hangs
import Testing

@Suite("Trubbo Beta: product ids and invite links per app (#234)")
struct BetaAppTests {
    @Test("The beta app asks StoreKit for beta.-prefixed ids, the live app for the live ones")
    func storeProductIDs() {
        #expect(BetaApp.storeProductID("pack_30", isBeta: true) == "beta.pack_30")
        #expect(BetaApp.storeProductID("com.carquiz.unlimited.monthly", isBeta: true)
            == "beta.com.carquiz.unlimited.monthly")
        #expect(BetaApp.storeProductID("pack_30", isBeta: false) == "pack_30")
    }

    @Test("Builds without BETA keep the unprefixed ids the local StoreKit config and the live catalog use")
    func nonBetaBuildIsUnprefixed() {
        // Hangs-Local's variant is NO like the beta's; only Prod adds BETA, so
        // the local StoreKit tests still find their products.
        #expect(!BetaApp.isBetaBuild)
        #expect(StoreProduct.monthlySubId == "com.carquiz.unlimited.monthly")
        #expect(StoreProduct.packId == "com.carquiz.pack.questions100")
        #expect(PackSize.thirty.storeProductId == "pack_30")
    }

    @Test("A pack size is found from the live id and from this app's store id")
    func packSizeFromEitherID() {
        // The StoreKit transaction names the store id (captured proof); orders
        // coming back from the server name the live one.
        #expect(PackSize(productId: "pack_10") == .ten)
        #expect(PackSize(productId: PackSize.ten.storeProductId) == .ten)
        #expect(PackSize(productId: "pack_99") == nil)
    }

    @Test("The beta app shares and opens invites on /beta/join, the live app on /join")
    func invitePathPerApp() throws {
        let created = RoomCreated(roomId: "r", joinToken: "abc", sessionId: "s")
        let beta = created.inviteURL(isBeta: true)
        let live = created.inviteURL(isBeta: false)
        #expect(beta.absoluteString == "https://trubbo.app/beta/join?t=abc")
        #expect(live.absoluteString == "https://trubbo.app/join?t=abc")

        #expect(RoomInvite.token(from: beta, isBeta: true) == "abc")
        #expect(RoomInvite.token(from: live, isBeta: false) == "abc")
        // Each app ignores the other's link: iOS routes it to the other app.
        #expect(RoomInvite.token(from: live, isBeta: true) == nil)
        #expect(RoomInvite.token(from: beta, isBeta: false) == nil)
        #expect(try RoomInvite.invite(from: #require(URL(string: "https://trubbo.app/beta/join?t=abc#qr")), isBeta: true)
            == .qr("abc"))
    }
}
