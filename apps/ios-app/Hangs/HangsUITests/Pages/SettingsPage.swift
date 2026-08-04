//
//  SettingsPage.swift
//  HangsUITests
//
//  Page Object for the Settings → Custom Pack flow (issue #111 T4, reworked
//  for the #138 modal). Covers the full #95 pack-order depth used by
//  RS-pack-nav-start: Home → Settings → order sheet (form → summary → pay →
//  delivered). The order sheet is ONE modal now, not two pushed screens.
//

import XCTest

struct SettingsPage {
    let app: XCUIApplication

    /// A valid order prompt: any non-empty topic up to 1000 chars (#138).
    static let validPrompt = "A quiz about the history of space exploration"

    // MARK: - Home → Settings

    var moreSettingsButton: XCUIElement {
        app.buttons["home.moreSettings"]
    }

    /// Tap the Home "more settings" chip and wait for Settings to appear.
    func openSettings(timeout: TimeInterval = 5) {
        XCTAssertTrue(
            moreSettingsButton.waitForExistence(timeout: timeout),
            "SettingsPage: home.moreSettings button not found"
        )
        moreSettingsButton.tap()
        XCTAssertTrue(
            createPackButton.waitForExistence(timeout: timeout),
            "SettingsPage: packs.createPack not found after opening Settings"
        )
    }

    // MARK: - Settings → order sheet

    var createPackButton: XCUIElement {
        app.buttons["packs.createPack"]
    }

    /// Tap "Create a pack" and wait for the order form step of the modal.
    func openCreatePack(timeout: TimeInterval = 5) {
        XCTAssertTrue(
            createPackButton.waitForExistence(timeout: timeout),
            "SettingsPage: packs.createPack button not found"
        )
        createPackButton.tap()
        XCTAssertTrue(
            promptField.waitForExistence(timeout: timeout),
            "SettingsPage: orderPack.prompt not found after opening Create Pack"
        )
    }

    // MARK: - Order sheet: form → summary → pay

    /// `TextField(axis: .vertical)` can surface as either a text field or a
    /// text view depending on the multiline backing store, so match by
    /// identifier across any element type rather than a specific query type.
    var promptField: XCUIElement {
        app.descendants(matching: .any)["orderPack.prompt"]
    }

    /// Form step primary CTA ("Continue" → payment summary).
    var submitButton: XCUIElement {
        app.buttons["orderPack.submit"]
    }

    /// Summary step primary CTA ("Pay & create pack") — the point of no return.
    var payButton: XCUIElement {
        app.buttons["orderPack.pay"]
    }

    /// Type a topic, continue to the payment summary, and pay. #138 split the
    /// old single "Create pack" tap into these two steps, with the
    /// no-cancellation notice in between.
    func submitOrder(prompt: String = SettingsPage.validPrompt, timeout: TimeInterval = 5) {
        XCTAssertTrue(
            promptField.waitForExistence(timeout: timeout),
            "SettingsPage: orderPack.prompt not found"
        )
        promptField.tap()
        promptField.typeText(prompt)
        XCTAssertTrue(
            submitButton.waitForExistence(timeout: timeout),
            "SettingsPage: orderPack.submit not found"
        )
        XCTAssertTrue(
            submitButton.isEnabled,
            "SettingsPage: orderPack.submit is disabled — the prompt did not validate"
        )
        submitButton.tap()

        XCTAssertTrue(
            payButton.waitForExistence(timeout: timeout),
            "SettingsPage: orderPack.pay not found — the payment summary did not appear"
        )
        payButton.tap()
    }

    // MARK: - Order sheet (delivered)

    var startQuizButton: XCUIElement {
        app.buttons["orderProgress.startQuiz"]
    }

    /// Wait for the delivered CTA (the `--ui-test` `MockPackOrderService`
    /// default fixture delivers on the first poll) and tap it. Identifier kept
    /// from the pushed OrderProgress screen so the RS assertions stay stable.
    func startQuizFromProgress(timeout: TimeInterval = 10) {
        XCTAssertTrue(
            startQuizButton.waitForExistence(timeout: timeout),
            "SettingsPage: orderProgress.startQuiz not found — order did not reach .delivered"
        )
        startQuizButton.tap()
    }
}
