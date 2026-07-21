//
//  SettingsPage.swift
//  HangsUITests
//
//  Page Object for the Settings → Custom Pack flow (issue #111 T4). Covers
//  the full #95 pack-order depth used by RS-pack-nav-start:
//  Home → Settings → OrderPack → OrderProgress(delivered).
//

import XCTest

struct SettingsPage {
    let app: XCUIApplication

    /// A valid order prompt: the server (and OrderPackViewModel.isValid)
    /// require 10–1000 trimmed characters.
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

    // MARK: - Settings → OrderPack

    var createPackButton: XCUIElement {
        app.buttons["packs.createPack"]
    }

    /// Tap "Create a pack" and wait for the order form to appear.
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

    // MARK: - OrderPack → OrderProgress

    /// `TextField(axis: .vertical)` can surface as either a text field or a
    /// text view depending on the multiline backing store, so match by
    /// identifier across any element type rather than a specific query type.
    var promptField: XCUIElement {
        app.descendants(matching: .any)["orderPack.prompt"]
    }

    var submitButton: XCUIElement {
        app.buttons["orderPack.submit"]
    }

    /// Type a valid (≥10 char) prompt into the order form and tap Create pack.
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
            "SettingsPage: orderPack.submit is disabled — prompt may not meet the 10-char minimum"
        )
        submitButton.tap()
    }

    // MARK: - OrderProgress (delivered)

    var startQuizButton: XCUIElement {
        app.buttons["orderProgress.startQuiz"]
    }

    /// Wait for the delivered CTA (the `--ui-test` `MockPackOrderService`
    /// default fixture delivers on the first poll) and tap it.
    func startQuizFromProgress(timeout: TimeInterval = 10) {
        XCTAssertTrue(
            startQuizButton.waitForExistence(timeout: timeout),
            "SettingsPage: orderProgress.startQuiz not found — order did not reach .delivered"
        )
        startQuizButton.tap()
    }
}
