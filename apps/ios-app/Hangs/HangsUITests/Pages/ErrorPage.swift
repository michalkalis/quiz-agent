//
//  ErrorPage.swift
//  HangsUITests
//
//  Page Object for the quiz error screen (ErrorView): a failed start or
//  answer, with Try again and/or Go Home.
//

import XCTest

struct ErrorPage {
    let app: XCUIApplication

    var root: XCUIElement {
        app.descendants(matching: .any)["error.root"]
    }

    var title: XCUIElement {
        app.staticTexts["error.title"]
    }

    var retryButton: XCUIElement {
        app.buttons["error.retry"]
    }

    var homeButton: XCUIElement {
        app.buttons["error.home"]
    }

    func waitForError(timeout: TimeInterval = 10, scenario: String) {
        XCTAssertTrue(
            title.waitForExistence(timeout: timeout),
            "\(scenario): the error screen (error.title) did not appear within \(timeout)s"
        )
    }
}
