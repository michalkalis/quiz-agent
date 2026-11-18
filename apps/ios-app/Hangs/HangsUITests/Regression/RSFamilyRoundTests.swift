//
//  RSFamilyRoundTests.swift
//  HangsUITests
//
//  RS-44 — a round with kids plays through the existing game screens (#236;
//  founder 2026-11-18: no family-specific UI in the game). `--app-config-family`
//  turns the server switch on and plays a scripted round on the UI-test mocks
//  (`FamilyModeFixtures`, `FamilyMockScript`) of the size the app asks for;
//  `--ui-test-family-repeats` makes its start say it replays played questions.
//

import XCTest

final nonisolated class RSFamilyRoundTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: RS-44a — S deťmi → 4–6 (repeats) → 6 questions → round end → Play Again

    // Regression guarded: a round started from „S deťmi“ must ask for the
    // band's round (6 for 4–6), play through the ordinary question and result
    // screens even when the server says it repeats played questions, end on
    // the ordinary round end without the "Send to a friend" card the server
    // would refuse for a round with kids, and Play Again must replay the
    // family round, never fall back to an adult one.
    @MainActor
    func testRS44aYoungestRoundPlaysThroughAndReplays() {
        let app = RSFlow.launch(["--app-config-family", "--ui-test-family-repeats", "--app-config-shared-quiz"])
        let home = HomePage(app: app)
        startFamilyRound(app, home: home, band: "kids_4_6")

        let question = QuestionPage(app: app)
        let result = ResultPage(app: app)
        for number in 1 ... 6 {
            question.waitForQuestion(timeout: 15)
            if number == 1 {
                XCTAssertEqual(counter(app), "1/6", "RS-44a: a 4–6 round is not 6 questions")
            }
            XCTAssertTrue(question.option("a").waitForExistence(timeout: 5), "RS-44a: question \(number) has no choices")
            question.option("a").tap()
            result.waitForResult(timeout: 15)
            if result.continueButton.exists { result.continueButton.tap() }
        }

        let playAgain = app.buttons["completion.playAgain"]
        XCTAssertTrue(playAgain.waitForExistence(timeout: 15), "RS-44a: the round did not end on the round end")
        XCTAssertTrue(app.buttons["completion.home"].exists, "RS-44a: the round end has no Home")
        XCTAssertFalse(app.buttons["completion.sendToFriend"].exists, "RS-44a: a round with kids offers a link the server refuses")

        playAgain.tap()
        question.waitForQuestion(timeout: 15)
        XCTAssertTrue(question.option("a").waitForExistence(timeout: 5), "RS-44a: Play Again started an adult round")
        XCTAssertEqual(counter(app), "1/6", "RS-44a: Play Again lost the band's round size")
        RSFlow.assertAlive(app, "RS-44a")
    }

    // MARK: RS-44b — S deťmi → 7–9 → 10 questions skipped → round end → Home

    // Regression guarded: an older band's round is 10 voice questions on the
    // same screens and ends on the round end; Home keeps the family mode.
    @MainActor
    func testRS44bOlderRoundPlaysTenQuestionsToTheRoundEnd() {
        let app = RSFlow.launch(["--app-config-family"])
        let home = HomePage(app: app)
        startFamilyRound(app, home: home, band: "kids_7_9")

        let question = QuestionPage(app: app)
        let result = ResultPage(app: app)
        for number in 1 ... 10 {
            question.waitForQuestion(timeout: 15)
            if number == 1 {
                XCTAssertEqual(counter(app), "1/10", "RS-44b: a 7–9 round is not 10 questions")
            }
            question.skipButton.tap()
            result.waitForResult(timeout: 15)
            if result.continueButton.exists { result.continueButton.tap() }
        }

        let homeButton = app.buttons["completion.home"]
        XCTAssertTrue(homeButton.waitForExistence(timeout: 15), "RS-44b: the round did not end on the round end")
        homeButton.tap()
        XCTAssertTrue(home.startFamilyButton.waitForExistence(timeout: 10), "RS-44b: Home lost the family mode")
        RSFlow.assertAlive(app, "RS-44b")
    }

    @MainActor
    private func startFamilyRound(_: XCUIApplication, home: HomePage, band: String) {
        home.assertVisible()
        XCTAssertTrue(home.familyModeSegment.waitForExistence(timeout: 10), "RS-44: no mode switch on Home")
        home.familyModeSegment.tap()
        let bandButton = home.familyBand(band)
        XCTAssertTrue(bandButton.waitForExistence(timeout: 5), "RS-44: the first flip did not ask for the age")
        bandButton.tap()
        XCTAssertTrue(home.startFamilyButton.waitForExistence(timeout: 5), "RS-44: no Štart s deťmi")
        home.startFamilyButton.tap()
    }

    @MainActor
    private func counter(_ app: XCUIApplication) -> String {
        app.staticTexts["question.counter"].label
    }
}
