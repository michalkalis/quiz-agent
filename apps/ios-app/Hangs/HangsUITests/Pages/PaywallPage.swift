//
//  PaywallPage.swift
//  HangsUITests
//

import XCTest

struct PaywallPage {
    let app: XCUIApplication

    var purchaseButton: XCUIElement {
        app.buttons["paywall-purchase-button"]
    }

    var closeButton: XCUIElement {
        app.buttons["paywall-close-button"]
    }

    var restoreButton: XCUIElement {
        app.buttons["paywall-restore-button"]
    }

    /// Offline variant retry button (shown when StoreKit unreachable, e.g. in simulator).
    var offlineRetryButton: XCUIElement {
        app.buttons["paywall-offline-retry-button"]
    }

    /// Wait for the paywall to appear — accepts either the normal (purchase) or
    /// offline (retry) variant, since the simulator has no real StoreKit connectivity.
    func waitForPaywall(timeout: TimeInterval = 10) {
        let appeared = purchaseButton.waitForExistence(timeout: timeout / 2)
            || offlineRetryButton.waitForExistence(timeout: timeout / 2)
        XCTAssertTrue(appeared, "PaywallPage: neither paywall-purchase-button nor paywall-offline-retry-button found within \(timeout)s")
    }

    func tapClose() {
        closeButton.tap()
    }
}
