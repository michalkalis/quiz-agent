//
//  RSPaywallTests.swift
//  HangsUITests
//
//  RS-19..RS-21 — new paywall / purchase / restore scenarios (#180 track D).
//  Products come from Hangs.storekit, attached to the Hangs-Local scheme's Test
//  action, so the sheet is the REAL paywall over StoreKit Testing — not a mock.
//  The quota wall itself is seeded by `--ui-test-paywall` (createSession throws
//  the free-limit error).
//

import XCTest

final nonisolated class RSPaywallTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Hit the free wall from Home and wait for the paywall's purchasable
    /// branch. The offline branch is a FAIL here on purpose: it means products
    /// did not load, and every purchase/restore scenario below is then blind.
    @MainActor
    private func reachPurchasablePaywall(_ scenario: String, _ extra: [String] = []) -> (XCUIApplication, PaywallPage) {
        let app = RSFlow.launch(["--ui-test-paywall"] + extra)
        let home = HomePage(app: app)
        home.assertVisible()
        home.tapStartQuiz()

        let paywall = PaywallPage(app: app)
        let purchasable = paywall.purchaseButton.waitForExistence(timeout: 15)
        XCTAssertTrue(
            purchasable,
            "\(scenario): paywall-purchase-button never appeared — products did not load from Hangs.storekit (offline branch: \(paywall.offlineRetryButton.exists))"
        )
        return (app, paywall)
    }

    // MARK: RS-19 — Free wall shows purchasable plans and Restore

    // Regression guarded: the quota wall must offer a way out — the monthly
    // plan, the pack, one purchase CTA and Restore — all addressable. A paywall
    // that renders but cannot sell (offline branch on a working StoreKit) is
    // the #171/#174 TF-round class of bug.
    @MainActor
    func testRS19FreeWallShowsPlansAndRestore() async throws {
        let (app, paywall) = reachPurchasablePaywall("RS-19")

        XCTAssertTrue(app.buttons["paywall-plan-monthly"].exists, "RS-19: monthly plan row missing")
        XCTAssertTrue(app.buttons["paywall-plan-pack"].exists, "RS-19: pack row missing")
        XCTAssertTrue(paywall.purchaseButton.isEnabled, "RS-19: purchase CTA disabled with products loaded")
        XCTAssertTrue(paywall.restoreButton.exists, "RS-19: paywall-restore-button missing")
        XCTAssertTrue(paywall.closeButton.exists, "RS-19: paywall-close-x-button missing — no way back to Home")
        RSFlow.assertAlive(app, "RS-19")
    }

    // MARK: RS-20 — Restore with nothing to restore says so

    // Regression guarded: Restore on an account with no purchases must end in
    // the honest "nothing to restore" notice on the same sheet — not a silent
    // no-op, not a fake success, not a dismissed paywall.
    @MainActor
    func testRS20RestoreWithNothingToRestoreIsHonest() async throws {
        let (app, paywall) = reachPurchasablePaywall("RS-20")

        paywall.restoreButton.tap()

        let notice = app.descendants(matching: .any)["paywall.nothingToRestore"]
        XCTAssertTrue(notice.waitForExistence(timeout: 15), "RS-20: paywall.nothingToRestore never appeared after Restore")
        XCTAssertFalse(app.descendants(matching: .any)["paywall.success.headline"].exists, "RS-20: Restore claimed success with nothing to restore")
        XCTAssertTrue(paywall.purchaseButton.exists, "RS-20: the paywall dismissed itself on an empty restore")
        RSFlow.assertAlive(app, "RS-20")
    }

    // MARK: RS-21 — Purchase reaches the success state

    // Regression guarded: a purchase over StoreKit Testing must land the paywall
    // in its success branch — or the "finishing up" (activating) branch while
    // the entitlement reconciles — with no purchase error. On the iOS 26.5
    // simulator the test transaction completes with no confirmation sheet at
    // all; if one does appear it is confirmed, in the app first, SpringBoard second.
    @MainActor
    func testRS21PurchaseReachesSuccess() async throws {
        let (app, paywall) = reachPurchasablePaywall("RS-21")

        paywall.purchaseButton.tap()
        confirmStoreKitSheetIfShown(app)

        let success = app.descendants(matching: .any)["paywall.success.headline"]
        let activating = app.descendants(matching: .any)["paywall.activating.headline"]
        let landed = success.waitForExistence(timeout: 20) || activating.waitForExistence(timeout: 5)
        XCTAssertTrue(landed, "RS-21: paywall never reached its success/activating branch after the purchase")
        XCTAssertFalse(app.descendants(matching: .any)["paywall.purchaseError"].exists, "RS-21: paywall.purchaseError shown after a confirmed purchase")
        RSFlow.assertAlive(app, "RS-21")
    }

    // MARK: RS-39 — A failed purchase says so and grants nothing

    // Regression guarded (#235.5): when the store reports a failure the
    // paywall must say so on the same sheet and stay usable (buy again, or
    // close); it must not claim success, and the free wall must still stand.
    @MainActor
    func testRS39FailedPurchaseSaysSoAndGrantsNothing() {
        let (app, paywall) = reachPurchasablePaywall("RS-39", ["--ui-test-purchase-fail"])

        paywall.purchaseButton.tap()

        let error = app.descendants(matching: .any)["paywall.purchaseError"]
        XCTAssertTrue(error.waitForExistence(timeout: 10), "RS-39: no paywall.purchaseError after a failed purchase")
        assertNothingGranted(app, paywall, "RS-39")
    }

    // MARK: RS-40 — A cancelled purchase returns to the paywall quietly

    // Regression guarded (#235.5): closing the store sheet is the player's
    // choice, not a failure. The paywall comes back as it was, with no error
    // scare and no entitlement.
    @MainActor
    func testRS40CancelledPurchaseReturnsQuietly() {
        let (app, paywall) = reachPurchasablePaywall("RS-40", ["--ui-test-purchase-cancel"])

        paywall.purchaseButton.tap()

        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: paywall.purchaseButton)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed, "RS-40: the purchase CTA never came back after the cancel")
        XCTAssertFalse(app.descendants(matching: .any)["paywall.purchaseError"].exists, "RS-40: a cancel was shown as an error")
        assertNothingGranted(app, paywall, "RS-40")
    }

    // MARK: RS-45 — The limit reached on an answer: verdict, round end, then paywall

    // Regression guarded (#240.9, founder 2026-11-18): the server grades the
    // answer that reaches the monthly limit and sends its verdict with the
    // 429, but the app dropped it and showed only the paywall, so the player
    // never learnt the last answer or the round's score.
    @MainActor
    func testRS45LimitMidRoundShowsVerdictThenRoundEndThenPaywall() async throws {
        let app = RSFlow.launch(["--ui-test-quota-mid-round"])
        let result = try await RSFlow.reachResult(app, client: UITestClient(), scenario: "RS-45")
        let paywall = PaywallPage(app: app)

        XCTAssertTrue(result.verdict.exists, "RS-45: the last answer's verdict is missing")
        XCTAssertFalse(paywall.closeButton.exists, "RS-45: the paywall covered the verdict")

        let roundEnd = RoundEndPage(app: app)
        roundEnd.waitForScreen(timeout: 15, scenario: "RS-45")
        XCTAssertFalse(paywall.closeButton.exists, "RS-45: the paywall covered the end of the round at once")

        paywall.waitForPaywall(timeout: 20)
        paywall.tapClose()
        XCTAssertTrue(roundEnd.homeButton.waitForExistence(timeout: 5), "RS-45: closing the paywall did not land on the end of the round")
        RSFlow.assertAlive(app, "RS-45")
    }

    /// The paywall is still usable and nothing was unlocked: no success branch,
    /// the CTA can be tapped again, and after ✕ the free wall comes back on the
    /// next start.
    @MainActor
    private func assertNothingGranted(_ app: XCUIApplication, _ paywall: PaywallPage, _ scenario: String) {
        XCTAssertFalse(app.descendants(matching: .any)["paywall.success.headline"].exists, "\(scenario): the paywall claimed success")
        XCTAssertFalse(app.descendants(matching: .any)["paywall.activating.headline"].exists, "\(scenario): the paywall is activating a purchase that did not happen")
        XCTAssertTrue(paywall.purchaseButton.isEnabled, "\(scenario): the purchase CTA is disabled, the paywall is stuck")
        XCTAssertTrue(paywall.closeButton.isHittable, "\(scenario): no way out of the paywall")

        paywall.tapClose()
        let home = HomePage(app: app)
        home.assertVisible()
        home.tapStartQuiz()
        XCTAssertTrue(paywall.purchaseButton.waitForExistence(timeout: 15), "\(scenario): the free wall is gone, an entitlement was granted")
        XCTAssertFalse(QuestionPage(app: app).questionText.exists, "\(scenario): a quiz started past the free wall")
        RSFlow.assertAlive(app, scenario)
    }

    /// Confirms the StoreKit Testing purchase sheet if one shows up within a
    /// short window; returns quietly when the transaction completed without it.
    @MainActor
    private func confirmStoreKitSheetIfShown(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let labels = ["Subscribe", "Purchase", "Buy", "Confirm", "OK"]
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if app.descendants(matching: .any)["paywall.activating.headline"].exists
                || app.descendants(matching: .any)["paywall.success.headline"].exists
            {
                return
            }
            for host in [app, springboard] {
                for label in labels where host.buttons[label].exists && host.buttons[label].isHittable {
                    host.buttons[label].tap()
                    return
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
    }
}
