//
//  RSSharedQuizTests.swift
//  HangsUITests
//
//  RS-33 — a shared quiz link (#232). The link arrives through the test
//  listener (`/shared/open`), as if tapped in a message; the mocks answer
//  for the server (`SharedQuizFixtures`), so no backend is involved.
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
}
