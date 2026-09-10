//
//  ReviewBadgeTests.swift
//  HangsTests
//
//  #176 gating + wire contract. The review badge exists so the founder can tell,
//  while playing in TestFlight, whether the text in front of him was vouched for
//  by a human, by a machine, or refused by one. Two things must therefore hold,
//  and neither is worth anything unasserted:
//
//  1. The three TestFlight-only keys decode exactly as the backend sends them —
//     absent (not null) for every App Store payload, and an UNKNOWN badge state
//     from a newer backend must not break the question's decode.
//  2. The row is present on a TestFlight/Debug build and absent otherwise. "It
//     is behind a flag" means nothing until something checks the flag hides it.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

// MARK: - Wire contract

// `@MainActor` only because `ReviewBadgeStyle` resolves Theme colours, which are
// main-actor isolated; the decoding assertions themselves are isolation-agnostic.
@Suite("Question review-badge decoding (#176)")
@MainActor
struct ReviewBadgeDecodingTests {
    /// The minimum an App Store payload carries — the #176 keys are OMITTED,
    /// never null, so absence is what the client must tolerate.
    private static let appStoreJSON = """
    {
        "id": "q_001",
        "question": "What is 2+2?",
        "type": "text",
        "possible_answers": null,
        "difficulty": "easy",
        "topic": "Math",
        "category": "adults",
        "source_url": null,
        "source_excerpt": null
    }
    """

    private static func testFlightJSON(badge: String) -> String {
        """
        {
            "id": "q_002",
            "question": "Ktorý dravec letí najrýchlejšie?",
            "type": "text",
            "possible_answers": null,
            "difficulty": "medium",
            "topic": "Science",
            "category": "adults",
            "source_url": null,
            "source_excerpt": null,
            "generated_by": "session:opus",
            "review_badge": "\(badge)",
            "translation_language": "sk",
            "review_note": "answerability: flip"
        }
        """
    }

    @Test("a TestFlight payload decodes all three review fields")
    func decodesReviewFields() throws {
        let data = Self.testFlightJSON(badge: "translation_flagged").data(using: .utf8)!
        let question = try JSONDecoder().decode(Question.self, from: data)

        #expect(question.reviewBadge == "translation_flagged")
        #expect(question.translationLanguage == "sk")
        #expect(question.reviewNote == "answerability: flip")
    }

    @Test("an App Store payload (keys absent) decodes with all three nil")
    func absentKeysDecodeToNil() throws {
        let data = Self.appStoreJSON.data(using: .utf8)!
        let question = try JSONDecoder().decode(Question.self, from: data)

        #expect(question.reviewBadge == nil)
        #expect(question.translationLanguage == nil)
        #expect(question.reviewNote == nil)
    }

    /// A new backend state must degrade, not crash: the badge is a String on
    /// purpose, and an unrecognised value renders raw and muted.
    @Test("an unknown badge state still decodes and renders as itself")
    func unknownBadgeDecodes() throws {
        let data = Self.testFlightJSON(badge: "translation_teleported").data(using: .utf8)!
        let question = try JSONDecoder().decode(Question.self, from: data)

        #expect(question.reviewBadge == "translation_teleported")
        let style = ReviewBadgeStyle(rawValue: try #require(question.reviewBadge))
        #expect(style.isUnknown)
        #expect(style.label == nil, "an unknown state has no translated word — the raw value shows instead")
    }

    /// The five founder-decided states plus the two serve-path ones each need a
    /// word; only `approved` is deliberately silent (a green dot alone).
    @Test("every known state maps to a style, and only `approved` is wordless",
          arguments: [
              ("approved", false),
              ("pending_review", true),
              ("translation_machine", true),
              ("translation_flagged", true),
              ("translation_critical", true),
              ("translation_live", true),
              ("en_fallback", true),
          ])
    func knownStatesHaveStyles(state: String, hasLabel: Bool) {
        let style = ReviewBadgeStyle(rawValue: state)
        #expect(style.isUnknown == false)
        #expect((style.label != nil) == hasLabel)
    }
}

// MARK: - Build-channel gating on the two quiz screens

@MainActor
private func makeAskingViewModel(question: Question) -> QuizViewModel {
    let vm = Fixtures.makeViewModel()
    vm.currentSession = Fixtures.makeActiveSession()
    vm.currentQuestion = question
    vm.quizState = .askingQuestion
    return vm
}

@MainActor
private func makeResultViewModel(question: Question) -> QuizViewModel {
    let vm = Fixtures.makeViewModel()
    vm.currentSession = Fixtures.makeActiveSession()
    vm.quizState = .showingResult(question: question, evaluation: .previewCorrect)
    return vm
}

@MainActor
private func makeFlaggedQuestion() -> Question {
    Fixtures.makeQuestion(
        generatedBy: "session:opus",
        reviewBadge: "translation_flagged",
        translationLanguage: "sk",
        reviewNote: "bohemizmus v odpovedi"
    )
}

@Suite("Review badge row gating (#176)")
@MainActor
struct ReviewBadgeGatingTests {
    @Test("the question screen shows model · language · badge on a TestFlight build")
    func questionRowPresentWhenEnabled() async throws {
        let view = QuestionView(viewModel: makeAskingViewModel(question: makeFlaggedQuestion()), debugSurfaces: true)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "question.reviewBadge")
            }
            // The badge's word, not just the row: a coloured dot with no label
            // would pass a presence-only assertion while saying nothing.
            #expect(throws: Never.self) {
                try tree.find(text: "Translation · check")
            }
            #expect(throws: Never.self) { try tree.find(text: "session:opus") }
            #expect(throws: Never.self) { try tree.find(text: "SK") }
        }
    }

    /// The pre-#176 model caption shipped UNGATED (a "remove before App Store"
    /// TEMP surface that never got removed). This is the assertion that keeps it
    /// gated now that it is permanent.
    @Test("an App Store build renders no provenance row at all")
    func questionRowAbsentWhenDisabled() async throws {
        let view = QuestionView(viewModel: makeAskingViewModel(question: makeFlaggedQuestion()), debugSurfaces: false)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self, "no review badge row in the App Store build") {
                try tree.find(viewWithAccessibilityIdentifier: "question.reviewBadge")
            }
            #expect(throws: (any Error).self, "not even the model name, which used to leak ungated") {
                try tree.find(text: "session:opus")
            }
        }
    }

    @Test("the result meta row repeats the badge and its note on a TestFlight build")
    func resultRowPresentWhenEnabled() async throws {
        let view = ResultView(viewModel: makeResultViewModel(question: makeFlaggedQuestion()), debugSurfaces: true)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "result.reviewBadge")
            }
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "result.reviewNote")
            }
        }
    }

    @Test("an App Store build renders neither badge nor note on the result screen")
    func resultRowAbsentWhenDisabled() async throws {
        let view = ResultView(viewModel: makeResultViewModel(question: makeFlaggedQuestion()), debugSurfaces: false)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) {
                try tree.find(viewWithAccessibilityIdentifier: "result.reviewBadge")
            }
            #expect(throws: (any Error).self) {
                try tree.find(viewWithAccessibilityIdentifier: "result.reviewNote")
            }
        }
    }

    /// An `approved` question is the common case: the row still renders (the
    /// model name is there) but the badge contributes a silent green dot.
    @Test("approved renders the row without a badge word")
    func approvedIsWordless() async throws {
        let approved = Fixtures.makeQuestion(
            generatedBy: "session:opus",
            reviewBadge: "approved",
            translationLanguage: "en"
        )
        let view = QuestionView(viewModel: makeAskingViewModel(question: approved), debugSurfaces: true)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "question.reviewBadge")
            }
            #expect(throws: (any Error).self, "approved is a dot, never a word") {
                try tree.find(text: "Approved")
            }
        }
    }
}
