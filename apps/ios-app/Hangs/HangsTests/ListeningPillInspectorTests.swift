//
//  ListeningPillInspectorTests.swift
//  HangsTests
//
//  Issue #45 task 45.6: assertions for the ListeningPill component.
//  Copy varies by mode (the intent: each flow tells the driver what to say);
//  fill/stroke tokens and a11y id are verified via the internal mapping + the
//  rendered tree. vzor: AnswerOptionInspectorTests.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@Suite("ListeningPill Inspector Tests")
@MainActor
struct ListeningPillInspectorTests {
    // MARK: - Mode → copy mapping (why: each flow must prompt the right answer form)

    @Test("Open-ended mode prompts for a free answer")
    func openEndedCopy() {
        #expect(ListeningPill.Mode.openEnded.copy == "Listening — say your answer")
    }

    @Test("MCQ mode prompts for A–D or the answer")
    func mcqCopy() {
        #expect(ListeningPill.Mode.mcq.copy == "Listening — say A–D or the answer")
    }

    @Test("True/false mode prompts for true or false")
    func trueFalseCopy() {
        #expect(ListeningPill.Mode.trueFalse.copy == "Listening — say true or false")
    }

    // MARK: - Style tokens (why: pinkSoft fill + pink hairline read as "listening")

    @Test("Pill uses pinkSoft fill and pink stroke")
    func styleTokens() {
        let view = ListeningPill(mode: .mcq)
        #expect(view.fillColor == Theme.Hangs.Colors.pinkSoft)
        #expect(view.strokeColor == Theme.Hangs.Colors.pink)
    }

    // MARK: - Rendered structure (ViewInspector)

    @Test("Copy renders in the tree per mode")
    func copyAppearsInTree() async throws {
        let view = ListeningPill(mode: .trueFalse)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "Listening — say true or false")
            }
        }
    }

    @Test("Waveform SF Symbol renders")
    func waveformRenders() async throws {
        let view = ListeningPill(mode: .openEnded)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(ViewType.Image.self, where: {
                    try $0.actualImage().name() == "waveform"
                })
            }
        }
    }

    @Test("Accessibility identifier question.listeningPill is present")
    func accessibilityIdentifierPresent() async throws {
        let view = ListeningPill(mode: .mcq)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "question.listeningPill")
            }
        }
    }
}
