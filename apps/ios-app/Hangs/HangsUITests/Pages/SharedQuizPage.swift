//
//  SharedQuizPage.swift
//  HangsUITests
//
//  Page Object for #232 share a quiz by link: the comparison sheet a link
//  opens when it is not played (again), and the round end's send card.
//

import XCTest

struct SharedQuizPage {
    let app: XCUIApplication

    var ranking: XCUIElement {
        app.descendants(matching: .any)["sharedQuiz.ranking"]
    }

    var doneButton: XCUIElement {
        app.buttons["sharedQuiz.results.done"]
    }

    var sendToFriendCard: XCUIElement {
        app.buttons["completion.sendToFriend"]
    }

    func waitForRanking(timeout: TimeInterval = 10, scenario: String) {
        XCTAssertTrue(
            ranking.waitForExistence(timeout: timeout),
            "\(scenario): the comparison did not appear within \(timeout)s"
        )
    }
}
