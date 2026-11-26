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

    /// "hear it" — replays the question audio from the answer panel.
    var hearItButton: XCUIElement {
        app.buttons["result.hearIt"]
    }

    /// The quiz toolbar's pause: holds the auto-advance ⇄ resumes it (TF
    /// build 90: the footer's STAY/RESUME pill is gone).
    var pauseButton: XCUIElement {
        app.buttons["question.pause"]
    }

    /// TF build 90 (C1): opens the sheet with the question just answered.
    var showQuestionButton: XCUIElement {
        app.buttons["result.showQuestion"]
    }

    /// The verdict label in the result card header ("Correct" / "Wrong" /
    /// "Skipped") — the one surface that tells the driver what happened.
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

    /// Seconds left on the auto-advance countdown, read from the Next
    /// button's label ("…auto-advancing in 7 seconds") once the countdown
    /// runs; nil if it does not start within `timeout`.
    func waitForAutoAdvanceSeconds(timeout: TimeInterval = 3) -> Int? {
        let counting = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "auto-advancing in"), object: continueButton
        )
        guard XCTWaiter.wait(for: [counting], timeout: timeout) == .completed,
              let match = continueButton.label.firstMatch(of: /in (\d+) second/) else { return nil }
        return Int(match.1)
    }

    /// Wait for the result screen to go away (auto-advance or continue fired).
    func waitForDismissal(timeout: TimeInterval = 15, scenario: String) {
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: continueButton
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [gone], timeout: timeout), .completed,
            "\(scenario): result.continue still on screen after \(timeout)s"
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
