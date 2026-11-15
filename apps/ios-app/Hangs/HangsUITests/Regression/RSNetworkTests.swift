//
//  RSNetworkTests.swift
//  HangsUITests
//
//  RS-34 — a quiz start on a slow network (#235.1, a "bad network" switch for
//  tests). The mock server answers the first question late
//  (`--ui-test-network slow`, see MockNetworkService+Conditions), so the
//  in-flight start that every other scenario skips past is on screen.
//

import XCTest

final nonisolated class RSNetworkTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: RS-34 — A slow start shows Cancel, then the question

    // Regression guarded: on a slow server the start must stay visibly in
    // flight and cancellable on Home (the window in which the founder walked
    // to another tab on build 87), and the question must still arrive.
    @MainActor
    func testRS34SlowStartShowsCancelThenTheQuestion() {
        let app = RSFlow.launch([
            "--ui-test-network", "slow", "--ui-test-network-delay", "4",
            "--ui-test-network-calls", "startQuiz",
        ])
        let home = HomePage(app: app)
        home.assertVisible()

        home.tapStartQuiz()

        XCTAssertTrue(home.cancelStartButton.waitForExistence(timeout: 3), "RS-34: no Cancel on Home while the start is in flight")
        XCTAssertTrue(home.cancelStartButton.isHittable, "RS-34: Cancel is shown but cannot be tapped")
        let question = QuestionPage(app: app)
        XCTAssertFalse(question.questionText.exists, "RS-34: the question showed before the slow server answered")

        question.waitForQuestion(timeout: 15)
        question.waitForState("askingQuestion", timeout: 10)
        XCTAssertFalse(home.cancelStartButton.exists, "RS-34: Cancel is still up over the question")
        RSFlow.assertAlive(app, "RS-34")
    }
}
