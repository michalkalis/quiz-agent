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

    /// Wait for the paywall to appear.
    func waitForPaywall(timeout: TimeInterval = 10) {
        XCTAssertTrue(
            purchaseButton.waitForExistence(timeout: timeout),
            "PaywallPage: paywall-purchase-button not found within \(timeout)s"
        )
    }

    func tapClose() {
        closeButton.tap()
    }
}
