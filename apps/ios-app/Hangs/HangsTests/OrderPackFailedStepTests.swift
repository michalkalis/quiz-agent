//
//  OrderPackFailedStepTests.swift
//  HangsTests
//
//  #138 review finding 2: the soft poll timeout is not a failure the user can
//  retry — the order is still pending/in_progress server-side and the backend's
//  retry endpoint 409s anything that isn't `failed`. The state carries the flag;
//  this pins that the SCREEN actually honours it, because an exposed "Try again"
//  is what would put a raw 409 in front of the user.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@MainActor
@Suite("OrderPack failed step — retryable vs. still-working (#138)")
struct OrderPackFailedStepTests {
    @Test("a retryable failure offers Try again")
    func retryableOffersRetry() throws {
        let view = OrderPackFailedStep(
            message: "Pack generation failed.",
            onRetry: {},
            onClose: {}
        )

        #expect(throws: Never.self) {
            try view.inspect().find(viewWithAccessibilityIdentifier: "orderPack.retry")
        }
    }

    @Test("a non-retryable failure (refunded) exposes NO retry — only a close action")
    func nonRetryableHidesRetry() throws {
        let view = OrderPackFailedStep(
            message: "This order was refunded.",
            isRetryable: false,
            onRetry: {},
            onClose: {}
        )

        let tree = try view.inspect()
        #expect(throws: (any Error).self) {
            try tree.find(viewWithAccessibilityIdentifier: "orderPack.retry")
        }
        #expect(throws: Never.self) {
            try tree.find(viewWithAccessibilityIdentifier: "orderPack.gotIt")
        }
    }
}

@MainActor
@Suite("OrderPack still preparing (#240)")
struct OrderPackStillPreparingStepTests {
    // WHY (#240, 240.9): after about three minutes of waiting the player
    // landed on "Something went wrong", "cannot be retried" while the pack
    // was still being made. The screen must say it is on its way, where it
    // will appear, and give one way back.
    @Test("a pack still being made reads as on its way, with My packs and one way back, no retry")
    func stillPreparingIsNoFailure() throws {
        let view = OrderPackStillPreparingStep(onClose: {})
        let tree = try view.inspect()
        #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "orderPack.stillPreparing") }
        #expect(throws: Never.self) { try tree.find(text: "Still preparing your pack") }
        #expect(throws: Never.self) {
            try tree.find(text: "It is taking longer than usual. When it's ready, you'll find it in My packs.")
        }
        #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "orderPack.gotIt") }
        #expect(throws: (any Error).self) { try tree.find(viewWithAccessibilityIdentifier: "orderPack.retry") }
    }
}
