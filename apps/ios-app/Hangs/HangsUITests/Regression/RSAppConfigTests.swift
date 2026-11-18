//
//  RSAppConfigTests.swift
//  HangsUITests
//
//  RS-22..RS-23 — server switches for shipped builds (#193 task 193.9); RS-26..RS-27
//  the maintenance screen and the update card (#214). The
//  switch values are seeded by DEBUG launch arguments
//  (`AppConfigStore.debugSeed`), so no backend is involved.
//

import XCTest

final nonisolated class RSAppConfigTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: RS-22 — Forced update covers the app

    // Regression guarded: below the server's minimum version the player must
    // land on the update screen with a working way to the store, and Home
    // must not be reachable behind it.
    @MainActor
    func testRS22ForcedUpdateCoversTheApp() {
        let app = RSFlow.launch(["--app-config-update-required"])

        XCTAssertTrue(
            app.descendants(matching: .any)["update.message"].waitForExistence(timeout: 10),
            "RS-22: update screen missing"
        )
        XCTAssertTrue(app.buttons["update.open"].exists, "RS-22: update.open button missing")
        let start = app.buttons["home.startQuiz"]
        XCTAssertFalse(start.exists && start.isHittable, "RS-22: Home is still reachable behind the update screen")
        RSFlow.assertAlive(app, "RS-22")
    }

    // MARK: RS-23 — Notice dismisses; paused orders disable Create a pack (Home + Settings)

    // Regression guarded: the Home notice must be closable (it must never
    // become a permanent banner over the start button), and pausing orders on
    // the server must stop new orders without hiding the entry silently.
    @MainActor
    func testRS23NoticeDismissesAndPausedOrdersDisableCreatePack() {
        let app = RSFlow.launch(["--app-config-notice", "--app-config-orders-off"])

        let notice = app.descendants(matching: .any)["home.notice.text"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "RS-23: Home notice missing")
        app.buttons["home.notice.dismiss"].tap()
        XCTAssertTrue(notice.waitForNonExistence(timeout: 5), "RS-23: notice still shown after dismiss")

        let homeCreatePack = HomePage(app: app).revealCreatePack()
        XCTAssertTrue(homeCreatePack.waitForExistence(timeout: 5), "RS-23: Home create-pack card hidden while orders are paused")
        XCTAssertFalse(homeCreatePack.isEnabled, "RS-23: Home create-pack card is enabled while orders are paused")

        let settings = SettingsPage(app: app)
        settings.openSettings()
        XCTAssertFalse(settings.createPackButton.isEnabled, "RS-23: Create a pack is enabled while orders are paused")
        RSFlow.assertAlive(app, "RS-23")
    }

    // MARK: RS-26 — Maintenance covers the app

    // Regression guarded: with maintenance on, the player sees the
    // maintenance message instead of starting a quiz that would fail.
    @MainActor
    func testRS26MaintenanceCoversTheApp() {
        let app = RSFlow.launch(["--app-config-maintenance"])

        XCTAssertTrue(
            app.descendants(matching: .any)["maintenance.message"].waitForExistence(timeout: 10),
            "RS-26: maintenance screen missing"
        )
        let start = app.buttons["home.startQuiz"]
        XCTAssertFalse(start.exists && start.isHittable, "RS-26: Home is still reachable behind the maintenance screen")
        RSFlow.assertAlive(app, "RS-26")
    }

    // MARK: RS-27 — Update card on Home dismisses

    // Regression guarded: the optional update must stay optional. The card
    // offers the store and closes, and Home stays playable the whole time.
    @MainActor
    func testRS27UpdateCardOffersStoreAndDismisses() {
        let app = RSFlow.launch(["--app-config-update-recommended"])

        let dismiss = app.buttons["home.update.dismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 10), "RS-27: update card missing")
        XCTAssertTrue(app.buttons["home.update.open"].exists, "RS-27: update button missing")
        XCTAssertTrue(app.buttons["home.startQuiz"].exists, "RS-27: Home not playable next to the update card")
        dismiss.tap()
        XCTAssertTrue(dismiss.waitForNonExistence(timeout: 5), "RS-27: card still shown after dismiss")
        RSFlow.assertAlive(app, "RS-27")
    }
}
