//
//  ConfirmationPage.swift
//  HangsUITests
//
//  Page Object for the answer confirmation sheet (AnswerConfirmationView).
//
//  The sheet carries no hidden state probe of its own: its branch is read
//  structurally. `confirmation.answer` exists only in the transcript branch,
//  `confirmation.answerField` only while editing, and `confirmation.cancel`
//  only in the transcribing branch — which the instant mock STT never shows.
//

import XCTest

struct ConfirmationPage {
    let app: XCUIApplication

    var confirmButton: XCUIElement { app.buttons["confirmation.confirm"] }
    var cancelButton: XCUIElement { app.buttons["confirmation.cancel"] }
    var reRecordButton: XCUIElement { app.buttons["confirmation.reRecord"] }
    var editButton: XCUIElement { app.buttons["confirmation.edit"] }
    var editCancelButton: XCUIElement { app.buttons["confirmation.editCancel"] }

    /// Multiline `TextField(axis: .vertical)` — queried across element types
    /// because XCUI exposes it as a text view, not a text field.
    var answerField: XCUIElement { app.descendants(matching: .any)["confirmation.answerField"] }
    var answer: XCUIElement { app.staticTexts["confirmation.answer"] }
    var matchedOption: XCUIElement { app.staticTexts["confirmation.matchedOption"] }

    /// The sheet is up in any branch (confirm is rendered whenever the
    /// transcript branch is, and the sheet cannot be swiped away).
    var isPresented: Bool { confirmButton.exists }

    func waitForTranscript(timeout: TimeInterval = 10, scenario: String) {
        XCTAssertTrue(
            answer.waitForExistence(timeout: timeout),
            "\(scenario): confirmation.answer not found — the sheet never reached its transcript branch"
        )
    }

    func waitForDismissal(timeout: TimeInterval = 5, scenario: String) {
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: confirmButton
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [gone], timeout: timeout), .completed,
            "\(scenario): the confirmation sheet is still up after \(timeout)s"
        )
    }

    /// Enter edit mode and replace the whole transcript with `text`.
    /// The field opens with the transcript in it and no selection, so the
    /// cursor is placed at the end of the (single-line) text and the old
    /// characters are deleted before typing.
    func replaceAnswer(with text: String, scenario: String) {
        editButton.tap()
        XCTAssertTrue(
            answerField.waitForExistence(timeout: 3),
            "\(scenario): confirmation.answerField did not appear after tapping edit"
        )
        answerField.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        let existing = (answerField.value as? String) ?? ""
        answerField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count + 2))
        answerField.typeText(text)
    }
}
