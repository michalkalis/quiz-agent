//
//  RSResultTests.swift
//  HangsUITests
//
//  RS-12, RS-13, RS-15, RS-16, RS-17, RS-48 from docs/testing/regression-scenarios.md,
//  frozen into XCUITest (#180 track D): question-screen geometry, leaving the
//  quiz, the typed-answer path, and the result screen's read-aloud / pause /
//  resume controls. The unit halves of RS-11/13/16/17 stay in HangsTests.
//

import XCTest

final nonisolated class RSResultTests: XCTestCase {
    private let client = UITestClient()

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: RS-12 — Countdown does not reflow the pinned controls

    // Regression guarded (#59.2): the answer countdown lives inside the Record
    // button; as it ticks, the button's y-origin must stay put — no chip may
    // shove the question and the action row downward.
    @MainActor
    func testRS12CountdownDoesNotReflowPinnedControls() async throws {
        let app = RSFlow.launch()
        let question = RSFlow.startQuiz(app)
        XCTAssertTrue(question.recordButton.waitForExistence(timeout: 5), "RS-12: question.record missing")

        let y0 = question.recordButton.frame.minY
        // Real time on purpose: the countdown ticks once per second.
        try await Task.sleep(for: .seconds(2))
        let y1 = question.recordButton.frame.minY

        XCTAssertLessThan(abs(y1 - y0), 4, "RS-12: question.record moved from y=\(y0) to y=\(y1) while the countdown ran")
        XCTAssertTrue(question.recordButton.isHittable, "RS-12: question.record no longer hittable")
        RSFlow.assertAlive(app, "RS-12")
    }

    // MARK: RS-13 — Close mid-quiz returns Home

    // Regression guarded (#59.4): the X asks "End Quiz" / "End & See Results";
    // ending must land on Home without stranding the user behind an error
    // banner. The dead-session variant (endSession throws sessionNotFound) is
    // the unit half in HangsTests. The dialog's buttons are system alert
    // buttons that ignore accessibilityIdentifier, hence the label match
    // (English UI on the simulator).
    @MainActor
    func testRS13CloseMidQuizReturnsHome() async throws {
        let app = RSFlow.launch()
        let question = RSFlow.startQuiz(app)

        XCTAssertTrue(question.closeButton.waitForExistence(timeout: 3), "RS-13: question.closeButton missing")
        question.closeButton.tap()
        // a11y-id: system alert — UIAlertController drops identifiers; English is pinned by RSFlow.baseLaunchArguments
        let endQuiz = app.alerts.firstMatch.buttons["End Quiz"]
        XCTAssertTrue(endQuiz.waitForExistence(timeout: 3), "RS-13: the end-quiz confirmation did not appear")
        endQuiz.tap()

        // Reaching Home is the whole proof: an error would keep QuestionView
        // mounted behind its banner, and Home would never appear.
        HomePage(app: app).assertVisible(timeout: 5)
        RSFlow.assertAlive(app, "RS-13")
    }

    // MARK: RS-15 — Typed answer submits and reaches the result

    // Regression guarded (#59.6): the keyboard toggle, field and send button
    // form a working path to evaluation. The spec's in-flight indicator is not
    // observable here — the mock grades in the same run loop turn — so this
    // freezes the flow; the indicator stays with the exploratory /regression run.
    @MainActor
    func testRS15TypedAnswerReachesResult() async throws {
        let app = RSFlow.launch()
        let question = RSFlow.startQuiz(app)

        XCTAssertTrue(question.textInputToggle.waitForExistence(timeout: 3), "RS-15: question.textInputToggle missing")
        question.textInputToggle.tap()
        XCTAssertTrue(question.textField.waitForExistence(timeout: 3), "RS-15: question.textField did not appear")
        question.textField.tap()
        question.textField.typeText("Paris")
        XCTAssertTrue(question.textSubmit.isEnabled, "RS-15: question.textSubmit stayed disabled with text entered")
        question.textSubmit.tap()

        let result = ResultPage(app: app)
        result.waitForResult(timeout: 8)
        result.assertVerdictContains("Correct")
        RSFlow.assertAlive(app, "RS-15")
    }

    // MARK: RS-46 — An open answer field closes when a quick skip moves on

    // Regression guarded (founder, TestFlight build 90): a quick-game skip
    // goes to the next question without the result screen, so the question
    // screen stays up, and the answer field the player had opened stayed open
    // on the next question with Type greyed out.
    @MainActor
    func testRS46QuickSkipClosesTypedAnswerField() async throws {
        let app = RSFlow.launch()
        let home = HomePage(app: app)
        home.assertVisible()
        home.choose("home.gameMode.quick", in: home.gameModeMenu, scenario: "RS-46")

        let question = RSFlow.startQuiz(app)
        question.textInputToggle.tap()
        XCTAssertTrue(question.textField.waitForExistence(timeout: 3), "RS-46: question.textField did not appear")
        question.skipButton.tap()

        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: question.textField)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 10), .completed, "RS-46: the answer field stayed open on the next question")
        XCTAssertTrue(question.textInputToggle.isEnabled, "RS-46: Type stayed greyed out on the next question")
        RSFlow.assertAlive(app, "RS-46")
    }

    // MARK: RS-48 — A silent quiz is answered by typing, without a time limit

    // Founder 2026-11-22 ("No sound", since #252 "Text game"): with it chosen on Home, the question
    // opens with the typed field ready and no Answer button, no countdown
    // moves it on by itself, the typed answer reaches the result, and the
    // result offers nothing to hear.
    @MainActor
    func testRS48SilentQuizIsTypedWithoutTimeLimit() async throws {
        let app = RSFlow.launch()
        let home = HomePage(app: app)
        home.assertVisible()
        home.choose("home.soundMode.text", in: home.soundModeMenu, scenario: "RS-48")

        let question = RSFlow.startQuiz(app)
        XCTAssertTrue(question.textField.waitForExistence(timeout: 3), "RS-48: the typed field is not open at once")
        XCTAssertFalse(question.recordButton.exists, "RS-48: a silent question offers the mic")
        XCTAssertFalse(question.textInputToggle.exists, "RS-48: Type is shown although the field is open")
        // Real time on purpose: a sound quiz shows its think countdown by now.
        try await Task.sleep(for: .seconds(5))
        question.waitForState("askingQuestion", timeout: 5)
        XCTAssertFalse(question.stopButton.exists, "RS-48: the mic opened by itself")
        XCTAssertFalse(app.descendants(matching: .any)["listen-bar"].exists, "RS-48: a countdown runs on a silent question")

        question.textField.tap()
        question.textField.typeText("Paris")
        question.textSubmit.tap()

        let result = ResultPage(app: app)
        result.waitForResult(timeout: 8)
        XCTAssertFalse(result.hearItButton.exists, "RS-48: the silent result offers read aloud")
        RSFlow.assertAlive(app, "RS-48")
    }

    // MARK: RS-16 — Read-aloud on the result does not advance

    // Regression guarded (#59.7): reading the explanation must not jump to the next question,
    // and the result waits while it is read. The spoken verdict's download is
    // held until the test has tapped, so the result's countdown (3 s after the
    // verdict since #240.9, which made the old 1.5 s wall-clock check race it)
    // cannot start first. The hold shows at once: the toolbar's pause turns
    // into Continue. The clock side is pinned in `ResultHearItHoldTests`.
    @MainActor
    func testRS16ReadAloudKeepsResultScreen() async throws {
        let app = RSFlow.launch()
        let question = RSFlow.startQuiz(app)
        let confirmation = try await RSFlow.recordAndCommit(
            app, question: question, transcript: "Paris", client: client, scenario: "RS-16"
        )
        try await client.holdNetwork(["downloadAudio"])
        confirmation.confirmButton.tap()
        let result = ResultPage(app: app)
        result.waitForResult(timeout: 15)
        let verdictBefore = result.verdict.label

        // #250: the explanation reads itself by default, so "hear it" is gone;
        // a tap on the explanation text is the replay.
        XCTAssertFalse(result.hearItButton.exists, "RS-16: 'hear it' beside an explanation that reads itself")
        XCTAssertTrue(result.explanationReadButton.waitForExistence(timeout: 3), "RS-16: result.explanationRead missing")
        result.explanationReadButton.tap()
        let held = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Continue"), object: result.pauseButton)
        XCTAssertEqual(XCTWaiter.wait(for: [held], timeout: 3), .completed, "RS-16: reading the explanation did not hold the result")

        try await client.releaseNetwork() // the verdict plays; a held result starts no countdown
        XCTAssertTrue(result.continueButton.exists, "RS-16: read-aloud left the result screen")
        XCTAssertEqual(result.verdict.label, verdictBefore, "RS-16: the verdict changed — a new question was graded")
        RSFlow.assertAlive(app, "RS-16")
    }

    // MARK: RS-17 — Resume auto-advance resumes, does not skip

    // Regression guarded (#59.8): pause holds the countdown; resume restarts it
    // and stays on the result — it must not share continueToNext(). Since TF
    // build 90 both are the toolbar's pause button (the STAY pill is gone). Proof of a
    // real resume: the result screen then leaves on its own within the 8 s
    // auto-advance window, which a stuck pause would never do.
    //
    // The pause tap races that real countdown, so the 8 s UITestSupport seeds
    // is a precondition, checked first. Before #243.8 (result pace presets) a
    // spoken verdict cut it to 3 s, and on a slow CI runner the result was
    // gone before the tap landed ("pause left the result screen").
    @MainActor
    func testRS17ResumeAutoAdvanceResumesCountdown() async throws {
        let app = RSFlow.launch()
        let result = try await RSFlow.reachResult(app, client: client, scenario: "RS-17")

        let secondsLeft = result.waitForAutoAdvanceSeconds()
        XCTAssertGreaterThanOrEqual(
            secondsLeft ?? 0, 5,
            "RS-17: the result counts down \(secondsLeft.map { "only \($0) s" } ?? "nothing"), the scenario needs the seeded 8 s"
        )

        XCTAssertTrue(result.pauseButton.waitForExistence(timeout: 3), "RS-17: question.pause missing")
        result.pauseButton.tap() // pause
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(result.continueButton.exists, "RS-17: pause left the result screen")

        result.pauseButton.tap() // resume
        XCTAssertTrue(result.continueButton.exists, "RS-17: resume skipped straight to the next question")

        result.waitForDismissal(timeout: 15, scenario: "RS-17 (countdown never resumed)")
        RSFlow.assertAlive(app, "RS-17")
    }
}
