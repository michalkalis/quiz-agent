//
//  RoundEndPage.swift
//  HangsUITests
//
//  Page Object for the solo end of round (`CompletionView`, ids `completion.*`).
//

import XCTest

struct RoundEndPage {
    let app: XCUIApplication

    /// #240.9: the line the end of the round opens with (best run, or the
    /// hardest right answer).
    var highlight: XCUIElement {
        app.staticTexts["completion.highlight"]
    }

    var homeButton: XCUIElement {
        app.buttons["completion.home"]
    }

    func waitForScreen(timeout: TimeInterval = 15, scenario: String) {
        XCTAssertTrue(
            highlight.waitForExistence(timeout: timeout),
            "\(scenario): the end of the round (completion.highlight) did not appear within \(timeout)s"
        )
    }
}
