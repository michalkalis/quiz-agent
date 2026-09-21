//
//  StoreKitSessionSmokeTests.swift
//  HangsTests
//
//  #180 track B — opt-in probe: can this toolchain run SKTestSession from the
//  unit-test host? On the iOS 26.4/26.5 simulator driven by `xcodebuild` the
//  StoreKit test daemon is unreachable — every session mutation fails with
//  SKInternalErrorDomain Code=3 (Apple FB22774836; re-verified 2026-09-21 on
//  Xcode 26.5, from the UI-test runner too). Until Apple fixes it the real
//  StoreKit edge cases live in `PurchaseEdgeCaseScenarioTests` (protocol
//  level); this probe exists so the fix is noticed the day it ships.
//
//  Run it deliberately (it is SKIPPED, visibly, by default — never a silent
//  pass, the May 2026 anti-pattern):
//    env TEST_RUNNER_HANGS_STOREKIT_LIVE=1 xcodebuild test … \
//      -only-testing:HangsTests/StoreKitSessionSmokeTests
//  It must FAIL loudly when the daemon is unreachable.
//

import Foundation
import StoreKit
import StoreKitTest
import Testing
@testable import Hangs

private final class BundleToken {}

@Suite(
    "StoreKit test session probe (opt-in: HANGS_STOREKIT_LIVE=1)",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["HANGS_STOREKIT_LIVE"] == "1")
)
@MainActor
struct StoreKitSessionSmokeTests {
    // Real-time limit, deliberately: an unreachable daemon makes
    // `Product.products` hang forever rather than throw (observed 2026-09-21),
    // and this opt-in probe has no injected clock to drive. The limit is the
    // loud failure.
    @Test(.timeLimit(.minutes(1)))
    func daemonReachableAndPackPurchaseCompletes() async throws {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "Hangs", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true
        try session.clearTransactions()

        let products = try await Product.products(for: ["com.carquiz.pack.questions100"])
        let product = try #require(products.first, "Product.products returned nothing — daemon unreachable?")

        let result = try await product.purchase()
        guard case let .success(verification) = result, case let .verified(tx) = verification else {
            Issue.record("purchase did not complete verified: \(result)")
            return
        }
        #expect(tx.productID == "com.carquiz.pack.questions100")
        await tx.finish()
        #expect(session.allTransactions().count == 1)
    }
}
