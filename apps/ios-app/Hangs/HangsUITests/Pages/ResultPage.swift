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

    /// The Anton verdict word in the result band ("NAILED IT." / "MISSED IT." /
    /// "SKIPPED.") — the one surface that tells the driver what happened.
    var verdict: XCUIElement {
        app.staticTexts["result.verdict"]
    }

    /// Wait for the result screen (result.continue button must appear).
    func waitForResult(timeout: TimeInterval = 10) {
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: timeout),
            "ResultPage: result.continue button not found within \(timeout)s"
        )
    }

    /// Assert the identified verdict element itself carries `substring` — not
    /// merely that some static text on screen contains it (which a stray label
    /// could satisfy while the verdict band rendered the wrong state).
    func assertVerdictContains(_ substring: String) {
        XCTAssertTrue(
            verdict.waitForExistence(timeout: 5),
            "ResultPage: result.verdict not found — the verdict band did not render"
        )
        XCTAssertTrue(
            verdict.label.contains(substring),
            "ResultPage: result.verdict is '\(verdict.label)', expected it to contain '\(substring)'"
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
