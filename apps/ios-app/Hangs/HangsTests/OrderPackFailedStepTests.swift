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

    @Test("a still-working timeout exposes NO retry — only a close action")
    func nonRetryableHidesRetry() throws {
        let view = OrderPackFailedStep(
            message: "Still working — check My packs later.",
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
