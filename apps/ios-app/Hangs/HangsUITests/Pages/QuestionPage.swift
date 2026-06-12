//
//  QuestionPage.swift
//  HangsUITests
//
//  Page Object for the Question screen.
//

import XCTest

struct QuestionPage {
    let app: XCUIApplication

    var questionText: XCUIElement {
        app.staticTexts["question.text"]
    }

    /// The Record button (non-recording state). The redesign (#52) renamed the
    /// old `question.micButton` to the semantic `question.record` / `question.stop`
    /// pair that toggles with state; RS taps Record to enter `.recording`.
    var recordButton: XCUIElement {
        app.buttons["question.record"]
    }

    var stopButton: XCUIElement {
        app.buttons["question.stop"]
    }

    var skipButton: XCUIElement {
        app.buttons["question.skip"]
    }

    /// Hidden state probe (DEBUG only). Returns the current QuizState case name.
    var stateLabel: XCUIElement {
        app.staticTexts["question.state"]
    }

    var closeButton: XCUIElement {
        app.buttons["question.closeButton"]
    }

    /// Wait for the question screen to appear (question.text must exist).
    func waitForQuestion(timeout: TimeInterval = 10) {
        XCTAssertTrue(
            questionText.waitForExistence(timeout: timeout),
            "QuestionPage: question.text not found within \(timeout)s"
        )
    }

    /// Wait for a specific state value in the hidden state probe.
    func waitForState(_ state: String, timeout: TimeInterval = 10) {
        let predicate = NSPredicate(format: "label == %@", state)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: stateLabel)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "QuestionPage: timed out waiting for state '\(state)'")
    }
}
