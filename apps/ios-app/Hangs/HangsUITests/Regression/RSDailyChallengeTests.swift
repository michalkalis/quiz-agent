//
//  RSDailyChallengeTests.swift
//  HangsUITests
//
//  RS-25 — the daily challenge click-through (#205). `--ui-test-daily-home`
//  turns the server switch on and plays a scripted five-question challenge
//  on the UI-test mocks (`DailyChallengeFixtures`), so no backend is involved.
//

import XCTest

final nonisolated class RSDailyChallengeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: RS-25 — Home card → five questions → daily round end → played card

    // Regression guarded: the daily challenge must play through the ordinary
    // quiz screens, show the crowd strip on the result card, end on its own
    // round end (Share + Home, never Play Again) and, back Home, the card
    // must show the day as played instead of offering it again.
    @MainActor
    func testRS25DailyChallengePlaysThroughToItsRoundEnd() {
        let app = RSFlow.launch(["--ui-test-daily-home"])
        let home = HomePage(app: app)
        home.assertVisible()

        XCTAssertTrue(home.dailyPlayButton.waitForExistence(timeout: 10), "RS-25: no daily challenge card on Home")
        home.dailyPlayButton.tap()

        let question = QuestionPage(app: app)
        let result = ResultPage(app: app)
        let crowd = app.descendants(matching: .any)["result.crowd"]
        for number in 1 ... 5 {
            question.waitForQuestion(timeout: 15)
            question.skipButton.tap()
            result.waitForResult(timeout: 15)
            // The script: skipping question 3 is "Nikto iný to nevedel.",
            // question 4 is the day's first answer; 1, 2 and 5 carry no strip.
            if number == 3 || number == 4 {
                XCTAssertTrue(crowd.waitForExistence(timeout: 5), "RS-25: question \(number) result has no crowd strip")
            } else {
                XCTAssertFalse(crowd.exists, "RS-25: question \(number) result shows a crowd strip it was not sent")
            }
            if result.continueButton.exists { result.continueButton.tap() }
        }

        let end = DailyRoundEndPage(app: app)
        end.waitForScreen(scenario: "RS-25")
        XCTAssertTrue(end.tiles.exists, "RS-25: the round end has no tiles")
        XCTAssertTrue(end.shareButton.exists, "RS-25: the round end has no Share")
        XCTAssertFalse(app.buttons["completion.playAgain"].exists, "RS-25: a second attempt is offered")

        end.homeButton.tap()
        XCTAssertTrue(home.dailyOpenButton.waitForExistence(timeout: 10), "RS-25: back Home the day is not shown as played")
        XCTAssertFalse(home.dailyPlayButton.exists, "RS-25: a played day is offered again")
        RSFlow.assertAlive(app, "RS-25")
    }
}
