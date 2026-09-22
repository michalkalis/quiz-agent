//
//  RSResultTests.swift
//  HangsUITests
//
//  RS-12, RS-13, RS-15, RS-16, RS-17 from docs/testing/regression-scenarios.md,
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
        result.assertVerdictContains("NAILED IT.")
        RSFlow.assertAlive(app, "RS-15")
    }

    // MARK: RS-16 — Read-aloud on the result does not advance

    // Regression guarded (#59.7): "hear it" replays the question audio and
    // leaves the auto-advance countdown alone — tapping it must not jump to the
    // next question. (Default auto-advance is 8 s; this check lands well inside.)
    @MainActor
    func testRS16ReadAloudKeepsResultScreen() async throws {
        let app = RSFlow.launch()
        let result = try await RSFlow.reachResult(app, client: client, scenario: "RS-16")
        let verdictBefore = result.verdict.label

        XCTAssertTrue(result.hearItButton.waitForExistence(timeout: 3), "RS-16: result.hearIt missing")
        result.hearItButton.tap()
        try await Task.sleep(for: .seconds(1.5))

        XCTAssertTrue(result.continueButton.exists, "RS-16: read-aloud left the result screen")
        XCTAssertEqual(result.verdict.label, verdictBefore, "RS-16: the verdict changed — a new question was graded")
        RSFlow.assertAlive(app, "RS-16")
    }

    // MARK: RS-17 — Resume auto-advance resumes, does not skip

    // Regression guarded (#59.8): STAY pauses the countdown; RESUME restarts it
    // and stays on the result — it must not share continueToNext(). Proof of a
    // real resume: the result screen then leaves on its own within the 8 s
    // auto-advance window, which a stuck pause would never do.
    @MainActor
    func testRS17ResumeAutoAdvanceResumesCountdown() async throws {
        let app = RSFlow.launch()
        let result = try await RSFlow.reachResult(app, client: client, scenario: "RS-17")

        XCTAssertTrue(result.stayHereButton.waitForExistence(timeout: 3), "RS-17: result.stayHere missing")
        result.stayHereButton.tap() // STAY
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(result.continueButton.exists, "RS-17: STAY left the result screen")

        result.stayHereButton.tap() // RESUME
        XCTAssertTrue(result.continueButton.exists, "RS-17: RESUME skipped straight to the next question")

        result.waitForDismissal(timeout: 15, scenario: "RS-17 (countdown never resumed)")
        RSFlow.assertAlive(app, "RS-17")
    }
}
