//
//  RSNetworkTests.swift
//  HangsUITests
//
//  RS-34 — a quiz start on a slow network (#235.1, a "bad network" switch for
//  tests). The mock server answers the first question late
//  (`--ui-test-network slow`, see MockNetworkService+Conditions), so the
//  in-flight start that every other scenario skips past is on screen.
//  RS-35..RS-38 (#235.5, degraded conditions): a slow launch, the network
//  lost while answering, a slow start with a tab switch, a failed start.
//  `UITestClient.setNetwork` changes the condition while the app runs.
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

    // MARK: RS-35 — A slow launch keeps Home usable

    // Regression guarded: usage and the entitlement sync answer late on a cold
    // or weak connection. Home must be usable the whole time (Start and the
    // tab bar), the plan shows that it is loading, and it settles to the
    // player's real plan once the server answers. The calls are held, not
    // delayed: the runner's own launch waits would outlast a short delay.
    @MainActor
    func testRS35SlowLaunchKeepsHomeUsable() async throws {
        let app = RSFlow.launch([
            "--ui-test-plan-subscriber", "--ui-test-network-hold", "getUsage,syncEntitlements",
        ])
        let home = HomePage(app: app)
        let profile = ProfilePage(app: app)
        home.assertVisible()
        XCTAssertTrue(home.startQuizButton.isHittable, "RS-35: Start cannot be tapped while the launch calls hang")
        XCTAssertTrue(profile.profileTab.isHittable, "RS-35: the tab bar cannot be used while the launch calls hang")

        profile.profileTab.tap()
        let loading = app.descendants(matching: .any)["home.freePlanLoading"]
        let manage = app.buttons["home.planManageButton"]
        XCTAssertTrue(loading.waitForExistence(timeout: 5), "RS-35: the plan does not show that it is loading")
        profile.playTab.tap()
        XCTAssertTrue(home.startQuizButton.waitForExistence(timeout: 3), "RS-35: Home did not come back while the calls hang")
        XCTAssertTrue(home.startQuizButton.isHittable, "RS-35: Start cannot be tapped while the launch calls hang")

        try await UITestClient().releaseNetwork()
        profile.profileTab.tap()
        XCTAssertTrue(manage.waitForExistence(timeout: 10), "RS-35: the plan never settled to the subscriber's card")
        XCTAssertFalse(loading.exists, "RS-35: the loading placeholder stayed next to the loaded plan")
        XCTAssertFalse(app.buttons["home.freePlanRetryButton"].exists, "RS-35: a slow answer was shown as a failure")
        RSFlow.assertAlive(app, "RS-35")
    }

    // MARK: RS-36 — The network drops while answering; retry keeps the question

    // Regression guarded: an answer sent into a dead connection must not
    // vanish silently or strand the player. While the app retries on its own
    // (`TransientRetry`, 24 s) the player sees it working; then an error with
    // Try again and a way Home; Try again with the network back reopens the
    // same question, and the answer sent again is graded.
    @MainActor
    func testRS36AnswerLostToTheNetworkRetriesTheSameQuestion() async throws {
        let app = RSFlow.launch()
        let client = UITestClient()
        let question = RSFlow.startQuiz(app)
        let asked = question.questionText.label

        try await client.setNetwork("offline", calls: ["submitTextInput"])
        typeAnswer(question, "Paris", "RS-36")
        question.waitForState("processing", timeout: 5)

        let error = ErrorPage(app: app)
        error.waitForError(timeout: 40, scenario: "RS-36")
        XCTAssertTrue(error.retryButton.exists, "RS-36: no Try again after a lost answer")
        XCTAssertTrue(error.homeButton.exists, "RS-36: no way Home after a lost answer")
        XCTAssertFalse(ResultPage(app: app).continueButton.exists, "RS-36: a result showed for an answer the server never got")

        // Try again returns to the same open question; the answer goes again.
        try await client.setNetwork("clear")
        error.retryButton.tap()
        question.waitForState("askingQuestion", timeout: 5)
        XCTAssertEqual(question.questionText.label, asked, "RS-36: Try again moved to another question")
        typeAnswer(question, "Paris", "RS-36")

        let result = ResultPage(app: app)
        result.waitForResult(timeout: 10)
        result.assertVerdictContains("Correct")
        XCTAssertFalse(error.title.exists, "RS-36: the error screen stayed up after a successful retry")
        RSFlow.assertAlive(app, "RS-36")
    }

    // MARK: RS-37 — A slow start finishes on the question after a tab switch

    // Regression guarded (build 87): the player started a quiz on a slow
    // server and walked to Together; the tab bar vanished and the app had to
    // be killed. The start must land on the question wherever the player went,
    // and ending that quiz must bring the tab bar back.
    @MainActor
    func testRS37SlowStartWithTabSwitchLandsOnTheQuestion() {
        let app = RSFlow.launch([
            "--app-config-multiplayer",
            "--ui-test-network", "slow", "--ui-test-network-delay", "3",
            "--ui-test-network-calls", "startQuiz",
        ])
        let home = HomePage(app: app)
        let room = RoomPage(app: app)
        home.assertVisible()
        XCTAssertTrue(room.togetherButton.waitForExistence(timeout: 10), "RS-37: Together tab missing")

        home.tapStartQuiz()
        XCTAssertTrue(home.cancelStartButton.waitForExistence(timeout: 3), "RS-37: the start was not in flight")
        room.togetherButton.tap()

        let question = QuestionPage(app: app)
        question.waitForQuestion(timeout: 15)
        question.waitForState("askingQuestion", timeout: 10)

        question.closeButton.tap()
        // a11y-id: system alert — UIAlertController drops identifiers; English is pinned by RSFlow.baseLaunchArguments
        let endQuiz = app.alerts.firstMatch.buttons["End Quiz"]
        XCTAssertTrue(endQuiz.waitForExistence(timeout: 3), "RS-37: the end-quiz confirmation did not appear")
        endQuiz.tap()

        XCTAssertTrue(room.togetherButton.waitForExistence(timeout: 5), "RS-37: the tab bar did not come back after the quiz")
        XCTAssertTrue(room.togetherButton.isHittable, "RS-37: the tab bar is there but cannot be tapped")
        RSFlow.assertAlive(app, "RS-37")
    }

    // MARK: RS-38 — A failed start offers Try again and Home

    // Regression guarded: a server error on the start must end in an error the
    // player can act on (Try again, Go Home), and Home must work afterwards:
    // with the server back, the next start plays.
    @MainActor
    func testRS38FailedStartOffersTryAgainAndHome() async throws {
        let app = RSFlow.launch([
            "--ui-test-network", "server-error", "--ui-test-network-calls", "startQuiz",
        ])
        let home = HomePage(app: app)
        home.assertVisible()
        home.tapStartQuiz()

        let error = ErrorPage(app: app)
        error.waitForError(scenario: "RS-38")
        XCTAssertTrue(error.retryButton.exists, "RS-38: no Try again after a failed start")
        XCTAssertTrue(error.homeButton.exists, "RS-38: no way Home after a failed start")
        XCTAssertFalse(QuestionPage(app: app).questionText.exists, "RS-38: a question showed although the start failed")

        error.homeButton.tap()
        home.assertVisible()
        XCTAssertTrue(ProfilePage(app: app).profileTab.waitForExistence(timeout: 3), "RS-38: the tab bar is missing on Home after the error")

        try await UITestClient().setNetwork("clear")
        _ = RSFlow.startQuiz(app)
        RSFlow.assertAlive(app, "RS-38")
    }

    @MainActor
    private func typeAnswer(_ question: QuestionPage, _ text: String, _ scenario: String) {
        question.textInputToggle.tap()
        XCTAssertTrue(question.textField.waitForExistence(timeout: 3), "\(scenario): question.textField did not appear")
        question.textField.tap()
        question.textField.typeText(text)
        question.textSubmit.tap()
    }
}
