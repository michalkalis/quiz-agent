//
//  HomePage.swift
//  HangsUITests
//
//  Page Object for the Home screen.
//

import XCTest

struct HomePage {
    let app: XCUIApplication

    var startQuizButton: XCUIElement {
        app.buttons["home.startQuiz"]
    }

    /// "Create your own pack" — opens the same order sheet as Settings.
    var createPackButton: XCUIElement {
        app.buttons["home.createPack"]
    }

    /// Tap the Start Quiz button and return immediately (caller waits for destination).
    func tapStartQuiz() {
        startQuizButton.tap()
    }

    /// Assert the home screen is visible by checking the Start Quiz button exists.
    func assertVisible(timeout: TimeInterval = 5) {
        XCTAssertTrue(
            startQuizButton.waitForExistence(timeout: timeout),
            "HomePage: home.startQuiz button not found"
        )
    }
}
