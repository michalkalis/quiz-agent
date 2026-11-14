//
//  PackSize.swift
//  Hangs
//
//  #228.6: the custom-pack sizes the App Store sells, one consumable each.
//  The product id must equal a `_PRODUCT_TIERS` key on quiz-pack-api
//  (`orders.py`): the server reads the pack's question count from the product
//  the StoreKit receipt names, so the size the buyer pays for is the size they
//  get.
//

import Foundation

nonisolated enum PackSize: Int, CaseIterable, Sendable {
    case ten = 10
    case thirty = 30

    /// The size every order had before 228.6, and still the preselected one.
    static let standard = PackSize.thirty

    var questionCount: Int { rawValue }

    /// The live product id, the one the server prices and counts by.
    var productId: String { "pack_\(rawValue)" }

    /// The id StoreKit sells this size under in this app (#234: `beta.`
    /// prefixed in Trubbo Beta).
    var storeProductId: String { BetaApp.storeProductID(productId) }

    /// The size a purchased product stands for; nil for any other product.
    /// Takes the live id or this app's store id: a StoreKit transaction names
    /// the store id, an order the server sends back names the live one.
    init?(productId: String) {
        guard let size = Self.allCases.first(where: { $0.productId == productId || $0.storeProductId == productId })
        else { return nil }
        self = size
    }
}
