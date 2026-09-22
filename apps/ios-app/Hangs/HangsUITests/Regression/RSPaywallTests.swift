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
    private func reachPurchasablePaywall(_ scenario: String) -> (XCUIApplication, PaywallPage) {
        let app = RSFlow.launch(["--ui-test-paywall"])
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

    /// Confirms the StoreKit Testing purchase sheet if one shows up within a
    /// short window; returns quietly when the transaction completed without it.
    @MainActor
    private func confirmStoreKitSheetIfShown(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let labels = ["Subscribe", "Purchase", "Buy", "Confirm", "OK"]
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if app.descendants(matching: .any)["paywall.activating.headline"].exists
                || app.descendants(matching: .any)["paywall.success.headline"].exists {
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
