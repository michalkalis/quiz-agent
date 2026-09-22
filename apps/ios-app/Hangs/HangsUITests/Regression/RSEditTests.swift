//
//  RSEditTests.swift
//  HangsUITests
//
//  RS-06..RS-08 from docs/testing/regression-scenarios.md, frozen into XCUITest
//  (#180 track D). Editing the transcript on the confirmation sheet: confirm
//  the edit, discard it by re-recording, or undo it and keep the sheet.
//
//  The mock's submitTextInput returns a canned evaluation regardless of the
//  text, so these scenarios prove the STATE MACHINE (edit → confirm reaches the
//  result, edit → re-record submits nothing), not that grading reacted to the
//  edited text — that lives in HangsTests.
//

import XCTest

final nonisolated class RSEditTests: XCTestCase {
    private let client = UITestClient()

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: RS-06 — Edit transcribed answer and confirm

    // Regression guarded: pencil → type a replacement → Confirm must reach
    // showingResult without the inline error (issue-19 bug-A class).
    @MainActor
    func testRS06EditAnswerAndConfirmReachesResult() async throws {
        let app = RSFlow.launch()
        let question = RSFlow.startQuiz(app)
        let confirmation = try await RSFlow.recordAndCommit(
            app, question: question, transcript: "Paris", client: client, scenario: "RS-06"
        )

        confirmation.replaceAnswer(with: "Lyon", scenario: "RS-06")
        confirmation.confirmButton.tap()

        let result = ResultPage(app: app)
        result.waitForResult(timeout: 10)
        RSFlow.assertNoErrorBanner(question, "RS-06")
        RSFlow.assertAlive(app, "RS-06")
    }

    // MARK: RS-07 — Edit then re-record dismisses without submitting

    // Regression guarded: entering edit mode and tapping Re-record must discard
    // the edit and never submit — no evaluation, no result screen, no error.
    // "Again" bridges through askingQuestion and starts the next recording
    // itself (see RS-05), so either state is the legal landing.
    @MainActor
    func testRS07EditThenReRecordDiscardsWithoutSubmitting() async throws {
        let app = RSFlow.launch()
        let question = RSFlow.startQuiz(app)
        let confirmation = try await RSFlow.recordAndCommit(
            app, question: question, transcript: "Paris", client: client, scenario: "RS-07"
        )

        confirmation.replaceAnswer(with: "Berlin", scenario: "RS-07")
        confirmation.reRecordButton.tap()

        question.waitForState(in: ["askingQuestion", "recording"], timeout: 5)
        confirmation.waitForDismissal(timeout: 3, scenario: "RS-07")
        XCTAssertFalse(
            ResultPage(app: app).continueButton.exists,
            "RS-07: a result screen appeared — Re-record submitted the edited answer"
        )
        RSFlow.assertNoErrorBanner(question, "RS-07")
        RSFlow.assertAlive(app, "RS-07")
    }

    // MARK: RS-08 — Cancel from the edit field restores the transcript

    // Regression guarded: cancel-from-edit is a local undo: exit edit mode,
    // restore the committed transcript, keep the sheet up — not a global
    // "abandon this answer" back to askingQuestion.
    @MainActor
    func testRS08CancelEditRestoresTranscriptAndKeepsSheet() async throws {
        let app = RSFlow.launch()
        let question = RSFlow.startQuiz(app)
        let confirmation = try await RSFlow.recordAndCommit(
            app, question: question, transcript: "Paris", client: client, scenario: "RS-08"
        )

        confirmation.replaceAnswer(with: "Berlin", scenario: "RS-08")
        confirmation.editCancelButton.tap()

        confirmation.waitForTranscript(timeout: 3, scenario: "RS-08")
        let shown = confirmation.answer.label
        XCTAssertTrue(shown.contains("Paris"), "RS-08: transcript not restored, sheet reads '\(shown)'")
        XCTAssertFalse(shown.contains("Berlin"), "RS-08: the discarded edit survived, sheet reads '\(shown)'")
        XCTAssertFalse(confirmation.answerField.exists, "RS-08: still in edit mode after cancel")
        XCTAssertNotEqual(
            question.stateValue, "askingQuestion",
            "RS-08: cancel-from-edit dismissed the whole sheet instead of undoing the edit"
        )
        RSFlow.assertNoErrorBanner(question, "RS-08")
        RSFlow.assertAlive(app, "RS-08")
    }
}
