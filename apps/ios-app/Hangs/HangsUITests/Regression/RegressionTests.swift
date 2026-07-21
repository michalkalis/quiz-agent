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
        // Order-independence: the template launch tests
        // (runsForEachTargetApplicationUIConfiguration) rotate the simulator to
        // landscape and the orientation persists across app launches. In
        // landscape the OrderPack submit button lays out below the 402pt-high
        // window, so its tap lands on nothing and the order is never created
        // (testRSPackNavStart then times out waiting for .delivered). Every RS
        // scenario assumes portrait — force it before each launch.
        XCUIDevice.shared.orientation = .portrait
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

    // MARK: - RS-pack-nav-start

    //
    // Scenario: push the full #95 custom-pack depth — Home→Settings→OrderPack→
    // OrderProgress(delivered) — then start the quiz from that deepest pushed
    // point, once via the "Start quiz" CTA and once via voice "start". Assert
    // QuestionView is the clean visible root (no Settings/OrderPack/OrderProgress
    // covering it) and the back-stack is empty.
    //
    // Regression guarded: NavigationModel's reactive teardown (#111) clears the
    // pushed stack + the OrderProgress `isPresented` child on every quiz-start
    // entry point — including the voice bypass (originally
    // QuizViewModel+CommandListener.swift:169) that shipped without any
    // teardown at all, and proves the belt-and-braces `isPresented` child
    // actually collapses rather than relying on SwiftUI's transitive pop.

    @MainActor
    func testRSPackNavStart() async throws {
        try await runPackNavStartPass(startVia: .ctaButton)
        try await runPackNavStartPass(startVia: .voiceCommand)
    }

    private enum PackNavStartTrigger {
        case ctaButton
        case voiceCommand
    }

    /// Drives Home→Settings→OrderPack→OrderProgress(delivered) from a fresh
    /// launch, fires "start" via `trigger`, then asserts QuestionView is the
    /// clean visible root with an empty back-stack. A fresh relaunch per pass
    /// is required — the first start tears the pushed chain down, so a second
    /// pass needs the chain freshly rebuilt, not a second assert on one stack.
    @MainActor
    private func runPackNavStartPass(startVia trigger: PackNavStartTrigger) async throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test"]
        app.launch()

        let settings = SettingsPage(app: app)
        settings.openSettings()
        settings.openCreatePack()
        settings.submitOrder()

        // Both triggers need the order delivered first — voice "start" must
        // fire from the same depth as the CTA, not merely once submitted.
        XCTAssertTrue(
            settings.startQuizButton.waitForExistence(timeout: 10),
            "RS-pack-nav-start: orderProgress.startQuiz not found — order did not reach .delivered"
        )

        switch trigger {
        case .ctaButton:
            settings.startQuizFromProgress()
        case .voiceCommand:
            try await client.sendCommand("start")
        }

        let question = QuestionPage(app: app)
        question.waitForQuestion(timeout: 15)

        XCTAssertTrue(
            question.recordButton.waitForExistence(timeout: 5),
            "RS-pack-nav-start (\(trigger)): question.record button not found after starting from OrderProgress"
        )
        XCTAssertTrue(
            question.recordButton.isHittable,
            "RS-pack-nav-start (\(trigger)): question.record button is not hittable — a pushed screen may still cover QuestionView"
        )
        question.waitForState("askingQuestion", timeout: 10)

        // A7: the back-stack is empty — no back button, and none of the
        // pushed screens' identifiers survive behind QuestionView. This is
        // what proves the OrderProgress `isPresented` child actually
        // dismissed (not just that `path` emptied), pinning the founder
        // default (post-pack-quiz lands on Home, not back in MyPacks).
        XCTAssertEqual(
            app.navigationBars.buttons.count, 0,
            "RS-pack-nav-start (\(trigger)): a navigation back button still exists — back-stack not empty"
        )
        for identifier in ["settings.voiceCommands", "packs.createPack", "orderPack.prompt", "orderPack.submit", "orderProgress.startQuiz"] {
            XCTAssertFalse(
                app.descendants(matching: .any)[identifier].exists,
                "RS-pack-nav-start (\(trigger)): '\(identifier)' still present — pushed stack not fully torn down"
            )
        }
    }
}
