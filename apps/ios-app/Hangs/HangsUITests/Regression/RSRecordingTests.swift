//
//  RSRecordingTests.swift
//  HangsUITests
//
//  RS-01..RS-05 from docs/testing/regression-scenarios.md, frozen into XCUITest
//  (#180 track D). Recording state machine: leaving `recording` on a committed
//  transcript, on the hard auto-stop, on a dropped connection, under a double
//  tap, and on re-record from the sheet.
//

import XCTest

final nonisolated class RSRecordingTests: XCTestCase {
    private let client = UITestClient()

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: RS-01 — Recording stops on committed transcript

    // Regression guarded: after STT commits the final transcript the app must
    // leave `recording`, surface the confirmation sheet with that transcript,
    // and not raise the inline error.
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

    // MARK: RS-02 — Hard auto-stop fires when no STT events arrive

    // Regression guarded: with no committed transcript ever landing, the 15 s
    // safety timer (Config.autoRecordingDuration, real time — not shortened
    // under --ui-test) must stop recording and route to a recoverable state.
    // If it lands on `error`, the banner text must be human-readable.
    @MainActor
    func testRS02HardAutoStopWithoutSTTEvents() async throws {
        let app = RSFlow.launch()
        let question = RSFlow.startQuiz(app)
        RSFlow.startRecording(question)

        // No STT events. The 15 s hard stop is the only thing that can end this.
        question.waitForStateToLeave("recording", timeout: 20)

        let landed = question.stateValue
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

    // Regression guarded: a dropped STT connection mid-recording shows the
    // inline error and returns to askingQuestion (#54 stuck-state class);
    // starting a fresh recording must clear that error.
    @MainActor
    func testRS03StaleErrorClearedByNextRecording() async throws {
        let app = RSFlow.launch()
        let question = RSFlow.startQuiz(app)
        RSFlow.startRecording(question)

        try await client.sendSTTEvent(path: "/stt/disconnect", text: nil)

        XCTAssertTrue(
            question.errorBanner.waitForExistence(timeout: 5),
            "RS-03: question.errorBanner never appeared after the STT drop"
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
