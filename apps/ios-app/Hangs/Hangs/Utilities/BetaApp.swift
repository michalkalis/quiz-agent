//
//  BetaApp.swift
//  Hangs
//
//  #234 — Trubbo Beta: the TestFlight build is its own app
//  (`com.missinghue.hangs.beta`) next to the App Store one. It is compiled
//  with the `BETA` condition (Prod.xcconfig, `APP_STORE_VARIANT=NO`); Local
//  and Staging never are, so the local StoreKit configuration keeps the
//  unprefixed ids.
//
//  App Store product ids are unique across the whole developer account, so the
//  beta app sells the same catalog as `beta.` + the live id. The server strips
//  the prefix for the beta bundle id only and works with the live id from
//  there on. Universal links: when both apps claim one path iOS doesn't promise
//  which one opens it, so the beta app invites through its own path.
//
//  The flag is injectable so both variants are unit-testable from one build.
//

import Foundation

nonisolated enum BetaApp {
    static let isBetaBuild: Bool = {
        #if BETA
            return true
        #else
            return false
        #endif
    }()

    static let productIDPrefix = "beta."

    /// The id StoreKit and RevenueCat know a product by in this app.
    static func storeProductID(_ productID: String, isBeta: Bool = isBetaBuild) -> String {
        isBeta ? productIDPrefix + productID : productID
    }

    /// The trubbo.app path the app's invite links use (AASA in apps/website).
    static func joinPath(isBeta: Bool = isBetaBuild) -> String {
        isBeta ? "/beta/join" : "/join"
    }
}
