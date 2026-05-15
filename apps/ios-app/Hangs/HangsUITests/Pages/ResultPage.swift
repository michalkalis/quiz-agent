//
//  ResultPage.swift
//  HangsUITests
//

import XCTest

struct ResultPage {
    let app: XCUIApplication

    var continueButton: XCUIElement {
        app.buttons["result.continue"]
    }

    var heroBanner: XCUIElement {
        app.otherElements["result.heroBanner"]
    }

    /// Wait for the result screen (result.continue button must appear).
    func waitForResult(timeout: TimeInterval = 10) {
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: timeout),
            "ResultPage: result.continue button not found within \(timeout)s"
        )
    }

    /// Assert that the hero text contains a given substring.
    func assertHeroContains(_ substring: String) {
        let predicate = NSPredicate(format: "label CONTAINS %@", substring)
        let match = app.staticTexts.matching(predicate).firstMatch
        XCTAssertTrue(
            match.waitForExistence(timeout: 3),
            "ResultPage: hero text does not contain '\(substring)'"
        )
    }
}
