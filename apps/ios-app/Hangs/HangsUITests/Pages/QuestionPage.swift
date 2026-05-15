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
        app.otherElements["question.text"]
    }

    var micButton: XCUIElement {
        app.buttons["question.micButton"]
    }

    var statusPill: XCUIElement {
        app.otherElements["question.statusPill"]
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
