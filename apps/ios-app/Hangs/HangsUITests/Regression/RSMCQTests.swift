//
//  RSMCQTests.swift
//  HangsUITests
//
//  RS-09 and RS-10 from docs/testing/regression-scenarios.md, frozen into
//  XCUITest (#180 track D). Multiple choice: the voice path goes through the
//  confirmation sheet prefilled with the matched option's VALUE (#171 track I,
//  #45 D4); the tap path submits directly.
//

import XCTest

final nonisolated class RSMCQTests: XCTestCase {
    private let client = UITestClient()

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: RS-09 — MCQ voice answer is matched, confirmed, graded

    // Regression guarded: a committed transcript matching an option prefills the
    // sheet with the option value (never the raw transcript) and shows the match
    // as "B · Jupiter"; nothing is graded until Confirm. Tolerant matching
    // (#171 I2) maps an inflected form the same way; an unmatched transcript
    // prefills the raw text unchanged. One fresh launch per variant.
    @MainActor
    func testRS09MCQVoiceAnswerGoesThroughConfirmation() async throws {
        try await runMCQVoicePass(transcript: "Jupiter", expectAnswer: "Jupiter", expectMatch: true)
        try await runMCQVoicePass(transcript: "Jupitera", expectAnswer: "Jupiter", expectMatch: true)
        try await runMCQVoicePass(transcript: "something unrelated", expectAnswer: "something unrelated", expectMatch: false)
    }

    @MainActor
    private func runMCQVoicePass(transcript: String, expectAnswer: String, expectMatch: Bool) async throws {
        let tag = "RS-09 (\(transcript))"
        let app = RSFlow.launch(["--ui-test-mcq"])
        let question = RSFlow.startMCQQuiz(app)

        XCTAssertTrue(question.option("a").exists, "\(tag): mcq.option.a missing — MCQ screen not rendered")

        // The fixture's 1 s answer timer auto-starts recording; no Record tap here.
        question.waitForState("recording", timeout: 10)
        let caption = question.answerListenBarLabel ?? ""
        XCTAssertTrue(
            caption.lowercased().contains("or the answer"),
            "\(tag): listen bar reads '\(caption)' — must say the option TEXT is accepted (#171 I3)"
        )

        try await client.sendSTTEvent(path: "/stt/committed", text: transcript)

        let confirmation = ConfirmationPage(app: app)
        confirmation.waitForTranscript(timeout: 5, scenario: tag)
        // The a11y label carries a spoken prefix ("Your transcribed answer: …"),
        // so the prefill is matched as the label's tail — exact, not contains,
        // so "Jupitera" cannot pass as "Jupiter".
        XCTAssertTrue(
            confirmation.answer.label.hasSuffix(expectAnswer),
            "\(tag): sheet reads '\(confirmation.answer.label)', expected it to end with '\(expectAnswer)'"
        )
        if expectMatch {
            XCTAssertTrue(confirmation.matchedOption.exists, "\(tag): confirmation.matchedOption missing")
            XCTAssertTrue(
                confirmation.matchedOption.label.contains("Jupiter"),
                "\(tag): matched option reads '\(confirmation.matchedOption.label)'"
            )
        } else {
            XCTAssertFalse(confirmation.matchedOption.exists, "\(tag): an unmatched transcript claims a match")
        }
        XCTAssertEqual(question.stateValue, "processing", "\(tag): nothing may be graded before Confirm")
        XCTAssertTrue(question.option("b").exists, "\(tag): options disappeared while the sheet is up")

        confirmation.confirmButton.tap()
        ResultPage(app: app).waitForResult(timeout: 10)
        RSFlow.assertNoErrorBanner(question, tag)
        RSFlow.assertAlive(app, tag)
    }

    // MARK: RS-10 — MCQ tap answer submits directly

    // Regression guarded: tapping an option is an explicit choice — it submits
    // straight to evaluation (processing → result) and does NOT open the
    // confirmation sheet the voice path uses. The mock grades instantly, so
    // `processing` is transient and the result screen is the observable.
    @MainActor
    func testRS10MCQTapAnswerSubmitsDirectly() async throws {
        let app = RSFlow.launch(["--ui-test-mcq"])
        let question = RSFlow.startMCQQuiz(app)

        XCTAssertTrue(question.option("b").waitForExistence(timeout: 3), "RS-10: mcq.option.b missing")
        question.option("b").tap()

        let result = ResultPage(app: app)
        result.waitForResult(timeout: 8)
        XCTAssertFalse(
            ConfirmationPage(app: app).isPresented,
            "RS-10: a tap on an option opened the confirmation sheet — taps must submit directly"
        )
        RSFlow.assertNoErrorBanner(question, "RS-10")
        RSFlow.assertAlive(app, "RS-10")
    }
}
