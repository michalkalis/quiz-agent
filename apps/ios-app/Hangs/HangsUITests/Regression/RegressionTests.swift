//
//  RegressionTests.swift
//  HangsUITests
//
//  Phase 5 XCUITest regression scenarios (issue #31).
//  Each method covers one regression scenario; the test name is the canonical
//  scenario identifier used by the /regression skill.
//
//  STT events are injected via the HTTP listener at 127.0.0.1:9999 (UITestClient)
//  rather than the URL scheme — the iOS 26.3 simulator drops custom scheme
//  delivery (kLSApplicationNotFoundErr); see memory project_ios26_url_scheme_bug.md.
//
//  Mock seeding: the app is launched with "--ui-test" (always) plus optional
//  variant flags "--ui-test-incorrect" and "--ui-test-paywall". UITestSupport.swift
//  wires deterministic mock services based on these flags.
//

import XCTest

final nonisolated class RegressionTests: XCTestCase {
    private let client = UITestClient()

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - RS-start

    //
    // Scenario: launch with mock services, tap Start Quiz, verify the quiz screen
    // appears and the mic button is hittable, and the state probe reads "askingQuestion".
    //
    // Regression guarded: StartNewQuiz happy path reaches .askingQuestion and
    // QuestionView renders the mic button.

    @MainActor
    func testRSStart() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test"]
        app.launch()

        let home = HomePage(app: app)
        home.assertVisible()
        home.tapStartQuiz()

        let question = QuestionPage(app: app)
        question.waitForQuestion(timeout: 15)

        XCTAssertTrue(
            question.recordButton.waitForExistence(timeout: 5),
            "RS-start: question.record button not found after navigation to question screen"
        )
        XCTAssertTrue(
            question.recordButton.isHittable,
            "RS-start: question.record button is not hittable"
        )

        question.waitForState("askingQuestion", timeout: 5)
    }

    // MARK: - RS-correct

    //
    // Scenario: from askingQuestion state, inject a committed STT event with the
    // correct answer, confirm via the confirmation sheet, and assert the result
    // screen shows the continue button (happy-path correct flow).
    //
    // Regression guarded: STT→processAnswer→showingResult pipeline for correct answers.

    @MainActor
    func testRSCorrect() async throws {
        let app = XCUIApplication()
        // Default --ui-test seeds previewAnswerCorrect as the text-input response.
        app.launchArguments = ["--ui-test"]
        app.launch()

        let home = HomePage(app: app)
        home.assertVisible()
        home.tapStartQuiz()

        let question = QuestionPage(app: app)
        question.waitForQuestion(timeout: 15)
        question.waitForState("askingQuestion", timeout: 10)

        // Tap Record to start recording — committed STT events are only consumed
        // while the VM is in .recording (handleCommittedTranscript guard).
        question.recordButton.tap()
        question.waitForState("recording", timeout: 5)

        // Inject a committed STT event (simulates user saying the answer).
        try await client.sendSTTEvent(path: "/stt/committed", text: "Paris")

        // Wait for the confirmation sheet to appear.
        let confirmButton = app.buttons["confirmation.confirm"]
        XCTAssertTrue(
            confirmButton.waitForExistence(timeout: 10),
            "RS-correct: confirmation.confirm not found after STT event"
        )
        confirmButton.tap()

        // Assert result screen appears with continue button.
        let result = ResultPage(app: app)
        result.waitForResult(timeout: 15)
    }

    // MARK: - RS-incorrect

    //
    // Scenario: same flow as RS-correct but launched with "--ui-test-incorrect"
    // so the mock returns an incorrect evaluation. Assert the hero text contains
    // "MISSED" (the incorrect-branch headline).
    //
    // Regression guarded: incorrect-answer branch of showingResult renders the
    // "MISSED\nIT." hero.

    @MainActor
    func testRSIncorrect() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test", "--ui-test-incorrect"]
        app.launch()

        let home = HomePage(app: app)
        home.assertVisible()
        home.tapStartQuiz()

        let question = QuestionPage(app: app)
        question.waitForQuestion(timeout: 15)
        question.waitForState("askingQuestion", timeout: 10)

        // Tap Record to enter .recording so handleCommittedTranscript will accept the event.
        question.recordButton.tap()
        question.waitForState("recording", timeout: 5)

        try await client.sendSTTEvent(path: "/stt/committed", text: "London")

        let confirmButton = app.buttons["confirmation.confirm"]
        XCTAssertTrue(
            confirmButton.waitForExistence(timeout: 10),
            "RS-incorrect: confirmation.confirm not found after STT event"
        )
        confirmButton.tap()

        let result = ResultPage(app: app)
        result.waitForResult(timeout: 15)
        result.assertHeroContains("MISSED")
    }

    // MARK: - RS-long

    //
    // Scenario: launch with "--ui-test-long" so the seeded voice question is
    // ~230 characters, navigate to the question screen, and assert the Record
    // and Skip buttons are hittable (isHittable is false when off-screen).
    //
    // Regression guarded: 54.2 — a long voice question must scroll instead of
    // pushing the Record/Skip action row below the screen.

    @MainActor
    func testRSLongQuestion() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test", "--ui-test-long"]
        app.launch()

        let home = HomePage(app: app)
        home.assertVisible()
        home.tapStartQuiz()

        let question = QuestionPage(app: app)
        question.waitForQuestion(timeout: 15)
        question.waitForState("askingQuestion", timeout: 10)

        XCTAssertTrue(
            question.recordButton.waitForExistence(timeout: 5),
            "RS-long: question.record button not found with a long question"
        )
        XCTAssertTrue(
            question.recordButton.isHittable,
            "RS-long: question.record button is not hittable — long question pushed it off-screen"
        )
        XCTAssertTrue(
            question.skipButton.isHittable,
            "RS-long: question.skip button is not hittable — long question pushed it off-screen"
        )
    }

    // MARK: - RS-paywall

    //
    // Scenario: launch with "--ui-test-paywall" so createSession throws
    // dailyLimitReached, tapping Start Quiz triggers the paywall sheet.
    // Tap the close button and assert the home screen reappears.
    //
    // Regression guarded: dailyLimitReached → showPaywall → dismiss → back to home.

    @MainActor
    func testRSPaywall() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test", "--ui-test-paywall"]
        app.launch()

        let home = HomePage(app: app)
        home.assertVisible()
        home.tapStartQuiz()

        let paywall = PaywallPage(app: app)
        paywall.waitForPaywall(timeout: 10)
        paywall.tapClose()

        home.assertVisible(timeout: 5)
    }
}
