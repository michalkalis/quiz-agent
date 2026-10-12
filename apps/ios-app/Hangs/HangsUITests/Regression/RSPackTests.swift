//
//  RSPackTests.swift
//  HangsUITests
//
//  RS-24 — a custom pack remembers what this phone played (#200, founder TF
//  test 2026-10-12). The played-through state is seeded by a DEBUG launch
//  argument; the pack list and the quiz run on the UI-test mocks.
//

import XCTest

final nonisolated class RSPackTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: RS-24 — A played-through pack asks before it starts over

    // Regression guarded: finishing a pack used to end in a raw server error
    // on the next start. The card must say how far the pack was played, the
    // start must ask first (nothing starts behind the alert), and "Start over"
    // must play the pack again.
    @MainActor
    func testRS24PlayedThroughPackAsksBeforeStartingOver() {
        let app = RSFlow.launch(["--ui-test-pack-played-through"])
        let home = HomePage(app: app)
        home.assertVisible()

        XCTAssertTrue(home.packProgress.waitForExistence(timeout: 10), "RS-24: the pack card shows no played count")
        home.packPlayButton.tap()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "RS-24: no start-over question for a played-through pack")
        let question = QuestionPage(app: app)
        XCTAssertFalse(question.questionText.exists, "RS-24: the quiz started behind the alert")

        alert.buttons["Start over"].tap() // a11y-id: system alert
        question.waitForQuestion(timeout: 15)
        RSFlow.assertAlive(app, "RS-24")
    }
}
