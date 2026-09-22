//
//  RSFlow.swift
//  HangsUITests
//
//  Shared steps for the numbered RS-NN scenarios (#180 track D — the
//  docs/testing/regression-scenarios.md registry frozen into XCUITest).
//  Every scenario starts from a fresh launch so its preconditions are explicit
//  and no state leaks between numbers.
//

import XCTest

@MainActor
enum RSFlow {
    /// Launch with `--ui-test` (mock services, HTTP listener) plus `extra` flags.
    /// Portrait is forced first: the template launch tests rotate the simulator
    /// and the orientation persists across launches (see RegressionTests.setUp).
    /// `--ui-test` (mock services, HTTP listener) with the UI pinned to
    /// English (#180 track E): locators go by accessibilityIdentifier, but the
    /// few labels XCUITest cannot avoid — system alert buttons, the StoreKit
    /// sheet — and the verdict/hero content assertions read English text, so
    /// the simulator's own language must not leak in.
    static let baseLaunchArguments = ["--ui-test", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]

    static func launch(_ extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = baseLaunchArguments + extra
        app.launch()
        return app
    }

    /// Home → Start quiz → question screen with the probe reading `askingQuestion`.
    static func startQuiz(_ app: XCUIApplication) -> QuestionPage {
        let home = HomePage(app: app)
        home.assertVisible()
        home.tapStartQuiz()
        let question = QuestionPage(app: app)
        question.waitForQuestion(timeout: 15)
        question.waitForState("askingQuestion", timeout: 10)
        return question
    }

    /// Same for the MCQ fixtures: their 1 s answer timer auto-starts recording,
    /// so the probe may already read `recording` by the first poll.
    static func startMCQQuiz(_ app: XCUIApplication) -> QuestionPage {
        let home = HomePage(app: app)
        home.assertVisible()
        home.tapStartQuiz()
        let question = QuestionPage(app: app)
        question.waitForQuestion(timeout: 15)
        question.waitForState(in: ["askingQuestion", "recording"], timeout: 10)
        return question
    }

    /// Tap Record and wait for `.recording` — committed STT events are only
    /// consumed in that state (handleCommittedTranscript guard).
    static func startRecording(_ question: QuestionPage) {
        question.recordButton.tap()
        question.waitForState("recording", timeout: 5)
    }

    /// Record, inject one committed transcript, wait for the sheet's transcript branch.
    static func recordAndCommit(
        _ app: XCUIApplication, question: QuestionPage, transcript: String,
        client: UITestClient, scenario: String
    ) async throws -> ConfirmationPage {
        startRecording(question)
        try await client.sendSTTEvent(path: "/stt/committed", text: transcript)
        let confirmation = ConfirmationPage(app: app)
        confirmation.waitForTranscript(timeout: 10, scenario: scenario)
        return confirmation
    }

    /// Full happy path to the result screen: start, record, commit, confirm.
    static func reachResult(
        _ app: XCUIApplication, client: UITestClient, scenario: String
    ) async throws -> ResultPage {
        let question = startQuiz(app)
        let confirmation = try await recordAndCommit(
            app, question: question, transcript: "Paris", client: client, scenario: scenario
        )
        confirmation.confirmButton.tap()
        let result = ResultPage(app: app)
        result.waitForResult(timeout: 15)
        return result
    }

    /// The only crash signal XCUITest has: the process is still in the foreground.
    static func assertAlive(_ app: XCUIApplication, _ scenario: String) {
        XCTAssertEqual(
            app.state, .runningForeground,
            "\(scenario): app is not running in the foreground — it crashed or exited"
        )
    }

    static func assertNoErrorBanner(_ question: QuestionPage, _ scenario: String) {
        XCTAssertFalse(
            question.errorBanner.exists,
            "\(scenario): question.errorBanner is showing '\(question.errorBanner.label)'"
        )
    }
}
