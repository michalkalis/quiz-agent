//
//  DailyRoundEndPage.swift
//  HangsUITests
//
//  Page Object for the #205 daily challenge round end.
//

import XCTest

struct DailyRoundEndPage {
    let app: XCUIApplication

    var screen: XCUIElement {
        app.descendants(matching: .any)["daily.end"]
    }

    var tiles: XCUIElement {
        app.descendants(matching: .any)["daily.tiles"]
    }

    var shareButton: XCUIElement {
        app.descendants(matching: .any)["daily.share"]
    }

    var homeButton: XCUIElement {
        app.buttons["daily.home"]
    }

    func waitForScreen(timeout: TimeInterval = 15, scenario: String) {
        XCTAssertTrue(
            screen.waitForExistence(timeout: timeout),
            "\(scenario): the daily round end did not appear within \(timeout)s"
        )
    }
}
