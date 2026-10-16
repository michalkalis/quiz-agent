//
//  RSRecordingTests.swift
//  HangsUITests
//
//  RS-01..RS-05 from docs/testing/regression-scenarios.md, frozen into XCUITest
//  (#180 track D). Recording state machine: leaving `recording` on a spoken
//  answer, on the hard auto-stop, on an audio interruption, under a double
//  tap, and on re-record from the sheet. #208.8: answers are recorded and
//  transcribed by the backend; the harness injects what the "server" heard.
//

import XCTest

final nonisolated class RSRecordingTests: XCTestCase {
    private let client = UITestClient()

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: RS-01 — Recording stops on the end of the spoken answer

    // Regression guarded: when the player stops speaking the app must leave
    // `recording`, upload the answer, surface the confirmation sheet with the
    // transcript the server heard, and not raise the inline error.
    @MainActor
    func testRS01RecordingStopsOnCommittedTranscript() async throws {
        let app = RSFlow.launch()
        let question = RSFlow.startQuiz(app)

        let confirmation = try await RSFlow.recordAndCommit(
            app, question: question, transcript: "Paris", client: client, scenario: "RS-01"
        )

        XCTAssertEqual(question.stateValue, "processing", "RS-01: probe should read processing while the sheet is up")
        XCTAssertTrue(
            confirmation.answer.label.contains("Paris"),
            "RS-01: confirmation.answer reads '\(confirmation.answer.label)', expected the committed transcript"
        )
        RSFlow.assertNoErrorBanner(question, "RS-01")
        RSFlow.assertAlive(app, "RS-01")
    }

    // MARK: RS-02 — Hard auto-stop fires when nothing is said

    // Regression guarded: with no answer ever spoken, the speech-start window
    // and the hidden dead-air cap (real time — not shortened under --ui-test)
    // must stop recording and route to a recoverable state.
    // If it lands on `error`, the banner text must be human-readable.
    @MainActor
    func testRS02HardAutoStopWithoutSTTEvents() async throws {
        let app = RSFlow.launch()
        let question = RSFlow.startQuiz(app)
        RSFlow.startRecording(question)

        // Nothing spoken. Only the recording's own deadlines can end this. The
        // first empty recording re-records once on its own (#185 track B, the
        // "didn't catch that" retry, passing through askingQuestion); the
        // second lands on the no-answer sheet (`processing`) or an error.
        let landed = question.waitForState(in: ["processing", "error"], timeout: 45)
        XCTAssertTrue(
            ["processing", "askingQuestion", "error"].contains(landed),
            "RS-02: auto-stop landed on '\(landed)', not a recoverable state"
        )
        if landed == "error" {
            let text = question.errorBanner.label
            XCTAssertFalse(text.isEmpty, "RS-02: error state with an empty banner")
            XCTAssertFalse(text.contains("Optional("), "RS-02: banner leaks an Optional: '\(text)'")
        }
        RSFlow.assertAlive(app, "RS-02")
    }

    // MARK: RS-03 — Stale error does not bleed into the next recording

    // Regression guarded: an audio interruption (phone call) mid-recording
    // shows the inline error and returns to askingQuestion (#54 / #67
    // stuck-state class); starting a fresh recording must clear that error.
    @MainActor
    func testRS03StaleErrorClearedByNextRecording() async throws {
        let app = RSFlow.launch()
        let question = RSFlow.startQuiz(app)
        RSFlow.startRecording(question)

        try await client.interruptRecording()

        XCTAssertTrue(
            question.errorBanner.waitForExistence(timeout: 5),
            "RS-03: question.errorBanner never appeared after the interruption"
        )
        question.waitForState("askingQuestion", timeout: 5)

        RSFlow.startRecording(question)

        RSFlow.assertNoErrorBanner(question, "RS-03")
        RSFlow.assertAlive(app, "RS-03")
    }

    // MARK: RS-04 — Rapid double-tap on the mic lands in a legal state

    // Regression guarded: reentrant record/stop taps must not violate
    // validTransitions or crash; the double-stop guard (isStoppingRecording) holds.
    @MainActor
    func testRS04DoubleTapOnMicLandsInLegalState() async throws {
        let app = RSFlow.launch()
        let question = RSFlow.startQuiz(app)

        question.recordButton.tap()
        // The button flips its identifier to question.stop the moment recording
        // starts; whichever face is up gets the second tap immediately.
        if question.stopButton.exists {
            question.stopButton.tap()
        } else if question.recordButton.exists {
            question.recordButton.tap()
        }

        let landed = question.waitForState(
            in: ["askingQuestion", "recording", "processing"], timeout: 5
        )
        XCTAssertFalse(landed.isEmpty, "RS-04: probe never settled on a legal state")
        RSFlow.assertAlive(app, "RS-04")
    }

    // MARK: RS-05 — Re-record from the sheet leaves processing

    // Regression guarded: dismissing the confirmation sheet without submitting
    // must leave `processing` so the user can record again — no orphaned
    // `processing`. `confirmation.cancel` exists only in the transcribing branch,
    // which the instant mock never shows, so the spec's fallback (Re-record) is
    // the path exercised here. "Again" passes through askingQuestion as a
    // transient bridge and starts the next recording itself (rerecordAnswer), so
    // either of the two is the legal landing state.
    @MainActor
    func testRS05ReRecordFromSheetLeavesProcessing() async throws {
        let app = RSFlow.launch()
        let question = RSFlow.startQuiz(app)
        let confirmation = try await RSFlow.recordAndCommit(
            app, question: question, transcript: "Paris", client: client, scenario: "RS-05"
        )

        if confirmation.cancelButton.exists {
            confirmation.cancelButton.tap()
        } else {
            confirmation.reRecordButton.tap()
        }

        question.waitForState(in: ["askingQuestion", "recording"], timeout: 5)
        confirmation.waitForDismissal(timeout: 3, scenario: "RS-05")
        RSFlow.assertAlive(app, "RS-05")
    }
}
