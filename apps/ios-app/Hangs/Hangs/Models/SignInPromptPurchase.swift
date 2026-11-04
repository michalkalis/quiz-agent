//
//  SignInPromptPurchase.swift
//  Hangs
//
//  #217.4 (founder 2026-11-04): what the player just bought, which is what the
//  sign-in prompt shows and offers to keep. Only a signed-in account carries a
//  purchase to a new phone: Apple restores Trubbo Plus, but question credit and
//  custom packs live on the server under whoever bought them.
//

import Foundation

enum SignInPromptPurchase: Equatable, Identifiable {
    case plus
    case credit(questionCount: Int)
    /// `colorKey` picks the pack's colour the way every other screen does
    /// (`Theme.Hangs.Category.style(forPack:)`).
    case customPack(name: String, questionCount: Int, colorKey: String)

    var id: String { analyticsKind.rawValue }

    var analyticsKind: SignInPromptKind {
        switch self {
        case .plus: .plus
        case .credit: .credit
        case .customPack: .customPack
        }
    }

    /// A finished credit purchase. `.activating` counts too: the money moved
    /// and the credit is on this phone's identity, the server mirror is just
    /// a few seconds behind.
    static func credit(after state: PurchaseState) -> SignInPromptPurchase? {
        switch state {
        case let .success(productID?), let .activating(productID?):
            productID == StoreProduct.packId ? .credit(questionCount: StoreProduct.packQuestionCount) : nil
        default:
            nil
        }
    }
}
