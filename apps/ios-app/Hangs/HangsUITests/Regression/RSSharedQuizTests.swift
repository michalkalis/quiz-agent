//
//  RSSharedQuizTests.swift
//  HangsUITests
//
//  RS-33 — a shared quiz link (#232). The link arrives through the test
//  listener (`/shared/open`), as if tapped in a message; the mocks answer
//  for the server (`SharedQuizFixtures`), so no backend is involved.
//  RS-43 (#235.5): a link that arrives while another quiz runs.
//

import XCTest

final nonisolated class RSSharedQuizTests: XCTestCase {
    private static let token = "rs33-shared-quiz"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: RS-33a — a friend's link starts the quiz from Home

    // Regression guarded: a friend's link must start its quiz at once, with
    // no tap on Home's Start (the friend may have just installed the app).
    @MainActor
    func testRS33aFriendsLinkStartsTheQuiz() async throws {
        let app = RSFlow.launch(["--app-config-shared-quiz"])
        let home = HomePage(app: app)
        home.assertVisible()

        try await UITestClient().openSharedQuizLink(token: Self.token)

        let question = QuestionPage(app: app)
        question.waitForQuestion(timeout: 15)
        XCTAssertFalse(SharedQuizPage(app: app).ranking.exists, "RS-33a: a first open must play, not compare")
        RSFlow.assertAlive(app, "RS-33a")
    }

    // MARK: RS-33b — an already played link shows its comparison

    // Regression guarded: a link played before must show who did how (✓/✗)
    // instead of an error or a second attempt.
    @MainActor
    func testRS33bPlayedLinkShowsTheComparison() async throws {
        try await assertComparison(flag: "--ui-test-shared-quiz-played", scenario: "RS-33b")
    }

    // MARK: RS-33c — the sender's own link shows the comparison

    // Regression guarded: the sender sees friends' results later only by
    // opening their own link; it must compare, never start the quiz again.
    @MainActor
    func testRS33cOwnLinkShowsTheComparison() async throws {
        try await assertComparison(flag: "--ui-test-shared-quiz-own", scenario: "RS-33c")
    }

    @MainActor
    private func assertComparison(flag: String, scenario: String) async throws {
        let app = RSFlow.launch(["--app-config-shared-quiz", flag])
        let home = HomePage(app: app)
        home.assertVisible()

        try await UITestClient().openSharedQuizLink(token: Self.token)

        let shared = SharedQuizPage(app: app)
        shared.waitForRanking(scenario: scenario)
        XCTAssertFalse(QuestionPage(app: app).questionText.exists, "\(scenario): the link started a quiz")
        shared.doneButton.tap()
        XCTAssertTrue(home.startQuizButton.waitForExistence(timeout: 5), "\(scenario): not back on Home")
        RSFlow.assertAlive(app, scenario)
    }

    // MARK: RS-43 — A link during a running quiz waits for it to end

    // Regression guarded (#235.5): a friend's link tapped mid-quiz must not
    // throw away the quiz being played or leave a stuck screen. It waits:
    // the running question stays, and the friend's quiz starts once the
    // player is back on Home.
    @MainActor
    func testRS43LinkDuringARunningQuizWaitsForItToEnd() async throws {
        let app = RSFlow.launch(["--app-config-shared-quiz"])
        let client = UITestClient()
        let question = RSFlow.startQuiz(app)
        // The friend's quiz starts slowly, so its start is seen on Home.
        try await client.setNetwork("slow", calls: ["startSharedQuiz"])

        try await client.openSharedQuizLink(token: Self.token)

        // Nothing to wait for on screen: give the link the same few run-loop
        // turns it takes to start a quiz from Home (RS-33a) and check that
        // the running question is untouched.
        let replaced = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", "askingQuestion"), object: question.stateLabel)
        XCTAssertEqual(XCTWaiter.wait(for: [replaced], timeout: 2), .timedOut, "RS-43: the link disturbed the running quiz (probe reads '\(question.stateValue)')")
        XCTAssertTrue(question.questionText.exists, "RS-43: the running question is gone")
        XCTAssertFalse(SharedQuizPage(app: app).ranking.exists, "RS-43: a comparison covered the running quiz")

        question.closeButton.tap()
        // a11y-id: system alert — UIAlertController drops identifiers; English is pinned by RSFlow.baseLaunchArguments
        let endQuiz = app.alerts.firstMatch.buttons["End Quiz"]
        XCTAssertTrue(endQuiz.waitForExistence(timeout: 3), "RS-43: the end-quiz confirmation did not appear")
        endQuiz.tap()

        // Back on Home the waiting link starts the friend's quiz by itself.
        let home = HomePage(app: app)
        XCTAssertTrue(home.cancelStartButton.waitForExistence(timeout: 5), "RS-43: the waiting link did not start the friend's quiz on Home")
        question.waitForQuestion(timeout: 15)
        question.waitForState("askingQuestion", timeout: 10)
        RSFlow.assertAlive(app, "RS-43")
    }
}
