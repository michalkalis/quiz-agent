//
//  ExplanationTapTests.swift
//  HangsTests
//
//  #243.9 (founder 2026-11-24, decision 4): the explanation on the result is
//  long to read at a glance; a tap anywhere on its text reads it aloud, the
//  same as the small "hear it" chip, which is a hard target in a car.
//

@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@Suite("#243.9: a tap on the explanation reads it")
@MainActor
struct ExplanationTapTests {
    private func panel(onHearIt: (() -> Void)?) -> ResultAnswerPanel {
        ResultAnswerPanel(
            answerLabel: "the answer",
            answerText: "Liechtenstein",
            isRecap: false,
            isCorrect: false,
            explanation: "It has had no standing army since 1868.",
            onHearIt: onHearIt
        )
    }

    @Test("tapping the explanation text runs the same read as hear it")
    func tapReads() async throws {
        var reads = 0
        let view = panel(onHearIt: { reads += 1 })
        try await ViewHosting.host(view) {
            try view.inspect().find(viewWithAccessibilityIdentifier: "result.explanationRead").button().tap()
        }
        #expect(reads == 1)
    }

    /// WHY: a silent quiz reads nothing, so its text must not pretend to be
    /// a control.
    @Test("without a read (silent quiz) the text is plain, not a button")
    func silentIsPlain() async throws {
        let view = panel(onHearIt: nil)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) { try tree.find(viewWithAccessibilityIdentifier: "result.explanationRead") }
            #expect(throws: Never.self) { try tree.find(text: "It has had no standing army since 1868.") }
        }
    }
}
