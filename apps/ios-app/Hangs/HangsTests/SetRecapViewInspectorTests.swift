//
//  SetRecapViewInspectorTests.swift
//  HangsTests
//
//  #132 Track E — recap variant C "Zoznam s rozbalením". Pins the flow-level
//  intent (verification altitude #57): the capture→display pipeline renders
//  one row per set question with the revealed answer visible WITHOUT
//  expanding, expanding adds you-said/explanation/hear-it, a skip stays
//  neutral, and the screen keeps the end-of-set exits (Play Again / Home).
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

// MARK: - Helpers

@MainActor
private func entry(
    number: Int,
    result: Evaluation.EvaluationResult,
    userAnswer: String = "Said Wrong",
    explanation: String? = "Because the melon grew in a box.",
    question: Question = Fixtures.makeQuestion(text: "What shape can melons be grown in?")
) -> RecapEntry {
    RecapEntry(
        number: number,
        question: question,
        evaluation: Evaluation(
            userAnswer: result == .skipped ? "" : userAnswer,
            result: result,
            points: 0,
            correctAnswer: "Pyramid",
            questionId: question.id,
            explanation: explanation,
            headlineAnswer: nil
        )
    )
}

/// A `.finished` view model whose ledger was filled through the real capture
/// path (three questions: correct, wrong, skipped).
@MainActor
private func makeRecapViewModel() async -> QuizViewModel {
    let (vm, _) = Fixtures.makeViewModelWithNetwork()
    vm.settings.answerRevealMode = .endOfSet
    vm.settings.autoRecordEnabled = false // recap must not auto-narrate in tests
    vm.settings.answerTimeLimit = 0
    vm.currentSession = Fixtures.makeQuizSession()

    for (result, answer) in [
        (Evaluation.EvaluationResult.correct, "Pyramid"),
        (.incorrect, "Cylinder"),
        (.skipped, ""),
    ] {
        vm.currentQuestion = Fixtures.makeQuestion(text: "Question about melons?")
        vm.quizState = result == .skipped ? .skipping : .processing
        let response = QuizResponse(
            success: true,
            message: "ok",
            session: Fixtures.makeQuizSession(),
            currentQuestion: Fixtures.makeQuestion(id: "q_next"),
            evaluation: Evaluation(
                userAnswer: answer,
                result: result,
                points: 0,
                correctAnswer: "Pyramid",
                questionId: "q_001",
                explanation: "Because the melon grew in a box.",
                headlineAnswer: nil
            ),
            feedbackReceived: [],
            audio: nil
        )
        let target = vm.recapEntries.count + 1
        // The recap entry is captured synchronously by `handleQuizResponse`; the
        // deferred-reveal advance it spawns only walks on to the next question
        // and would race this loop's state writes. Cancel it instead of waiting
        // real time for it to settle (#180 track A) — the ledger is what this
        // fixture is building.
        await vm.handleQuizResponse(response)
        vm.taskBag.cancel(.deferredAdvance)
        precondition(vm.recapEntries.count == target)
    }
    vm.quizState = .finished
    vm.taskBag.cancelAll()
    return vm
}

// MARK: - Screen

@Suite("SetRecapView — hero, rows, exits (#132 E)")
@MainActor
struct SetRecapViewInspectorTests {
    @Test("hero shows the correct-count score and the three buckets")
    func heroScoreAndChips() async throws {
        let vm = await makeRecapViewModel()
        let view = SetRecapView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "recap.hero")
            }
            #expect(throws: Never.self) { try tree.find(text: "1/3") }
            #expect(throws: Never.self) { try tree.find(text: "1 CORRECT") }
            #expect(throws: Never.self) { try tree.find(text: "1 MISSED") }
            #expect(throws: Never.self) { try tree.find(text: "1 SKIPPED") }
        }
    }

    @Test("every set question renders a row with its revealed answer visible collapsed")
    func rowsRenderCollapsedAnswers() async throws {
        let vm = await makeRecapViewModel()
        let view = SetRecapView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            for id in 1 ... 3 {
                #expect(throws: Never.self, "row \(id) missing") {
                    try tree.find(viewWithAccessibilityIdentifier: "recap.row.\(id)")
                }
            }
            // The revealed answer is on the collapsed row (variant C's point);
            // the explanation is not (it lives behind the expansion).
            #expect(throws: Never.self) { try tree.find(text: "Pyramid") }
            #expect(throws: (any Error).self) {
                _ = try tree.find(text: "Because the melon grew in a box.")
            }
        }
    }

    @Test("the recap keeps the end-of-set exits and the summary CTA")
    func exitsAndSummaryCTA() async throws {
        let vm = await makeRecapViewModel()
        let view = SetRecapView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            for id in ["recap.playSummary", "recap.playAgain", "recap.home", "recap.close"] {
                #expect(throws: Never.self, "\(id) missing") {
                    try tree.find(viewWithAccessibilityIdentifier: id)
                }
            }
            #expect(throws: Never.self) { try tree.find(text: "Play summary") }
        }
    }
}

// MARK: - Row

@Suite("SetRecapRow — expansion anatomy (#132 E)")
@MainActor
struct SetRecapRowInspectorTests {
    @Test("expanded wrong answer shows you-said struck through + explanation + hear it")
    func expandedWrongRow() async throws {
        let row = SetRecapRow(
            entry: entry(number: 2, result: .incorrect),
            isExpanded: true,
            hearItDisabled: false,
            onToggle: {},
            onHearIt: {}
        )
        try await ViewHosting.host(row) {
            let tree = try row.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "recap.row.2.said")
            }
            // The wrong answer itself is in the said-line (struck-through
            // styling is design, not flow — altitude #57 pins presence).
            #expect(throws: Never.self) { try tree.find(text: "Said Wrong") }
            #expect(throws: Never.self) {
                try tree.find(text: "Because the melon grew in a box.")
            }
            #expect(throws: Never.self) { try tree.find(text: "hear it") }
        }
    }

    /// "you said" belongs only to a wrong answer — a correct row's answer IS
    /// what was said, and a skip said nothing (#131 D).
    @Test("correct and skipped rows have no you-said line", arguments: [
        Evaluation.EvaluationResult.correct, .skipped,
    ])
    func noSaidLineOnCorrectOrSkipped(result: Evaluation.EvaluationResult) async throws {
        let row = SetRecapRow(
            entry: entry(number: 1, result: result),
            isExpanded: true,
            hearItDisabled: false,
            onToggle: {},
            onHearIt: {}
        )
        try await ViewHosting.host(row) {
            let tree = try row.inspect()
            #expect(throws: (any Error).self) {
                _ = try tree.find(viewWithAccessibilityIdentifier: "recap.row.1.said")
            }
        }
    }

    /// A row without an explanation (no gist served) must not dangle a dead
    /// hear-it link.
    @Test("no explanation → no hear-it link")
    func noExplanationNoHearIt() async throws {
        let row = SetRecapRow(
            entry: entry(number: 1, result: .incorrect, explanation: nil),
            isExpanded: true,
            hearItDisabled: false,
            onToggle: {},
            onHearIt: {}
        )
        try await ViewHosting.host(row) {
            let tree = try row.inspect()
            #expect(throws: (any Error).self) {
                _ = try tree.find(text: "hear it")
            }
        }
    }
}

// MARK: - Expanded row: whole question + source (#179 findings 5 & 8)

/// Founder, TestFlight 2026-09-14: the recap was the one screen showing every
/// answer of the set, and the one screen where you could neither read the whole
/// question nor check where the answer came from. Both halves are pinned here:
/// the 2-line teaser is a COLLAPSED rule only, and the source link the result
/// screen has must exist here too (same `HangsSourceLink`).
@Suite("SetRecapRow — full stem + source link when expanded (#179)")
@MainActor
struct SetRecapRowSourceAndStemTests {
    private static let longStem = """
    Which European capital city, founded as a Roman settlement on the banks of \
    a major river, later became the seat of a dual monarchy, and is today famous \
    for its thermal baths and a castle district listed by UNESCO?
    """

    private func row(
        expanded: Bool,
        question: Question,
        onOpenSource: @escaping (String) -> Void = { _ in }
    ) -> SetRecapRow {
        SetRecapRow(
            entry: entry(number: 3, result: .incorrect, question: question),
            isExpanded: expanded,
            hearItDisabled: false,
            onToggle: {},
            onHearIt: {},
            onOpenSource: onOpenSource
        )
    }

    /// A question with no source at all — the link must not dangle.
    private func sourcelessQuestion() -> Question {
        Question(
            id: "q_nosource",
            question: Self.longStem,
            type: .text,
            possibleAnswers: nil,
            difficulty: "medium",
            topic: "Test Topic",
            category: "test",
            sourceUrl: nil,
            sourceExcerpt: nil,
            mediaUrl: nil,
            imageSubtype: nil,
            explanation: nil,
            generatedBy: nil
        )
    }

    @Test("the capture keeps the question's source URL (it used to be dropped)")
    func entryCarriesSourceUrl() {
        let question = Fixtures.makeQuestion(text: Self.longStem)
        let captured = entry(number: 3, result: .incorrect, question: question)
        #expect(captured.sourceUrl == question.sourceUrl)
        #expect(HangsSourceLink.domain(from: captured.sourceUrl) == "example.com")
    }

    @Test("expanded renders the WHOLE stem — no line limit — plus the source link")
    func expandedShowsFullStemAndSource() async throws {
        let view = row(expanded: true, question: Fixtures.makeQuestion(text: Self.longStem))
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let stem = try tree.find(text: Self.longStem)
            #expect(try stem.lineLimit() == nil, "an expanded row must not truncate the question")
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "recap.row.3.source")
            }
        }
    }

    /// The collapsed list is unchanged — this is the regression half: the row
    /// stays a 2-line teaser with nothing new stacked into it.
    @Test("collapsed keeps the 2-line teaser and shows no source link")
    func collapsedUnchanged() async throws {
        let view = row(expanded: false, question: Fixtures.makeQuestion(text: Self.longStem))
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(try tree.find(text: Self.longStem).lineLimit() == 2)
            #expect(throws: (any Error).self) {
                _ = try tree.find(viewWithAccessibilityIdentifier: "recap.row.3.source")
            }
        }
    }

    /// The link must feed the recap's OWN `SourceWebView` sheet, not `openURL` —
    /// a driver bounced into Safari mid-recap has left the app. The row reports
    /// the URL and `SetRecapView` turns it into `sourceSheet`; a `@State` write
    /// is not visible to a re-inspection, so the contract is pinned at the seam
    /// the row owns: the callback, and the exact URL it carries.
    @Test("tapping the source link hands the URL to the owner for the in-app reader")
    func sourceLinkReportsURLToOwner() async throws {
        let question = Fixtures.makeQuestion(text: Self.longStem)
        var opened: String?
        let view = row(expanded: true, question: question) { opened = $0 }
        try await ViewHosting.host(view) {
            try view.inspect()
                .find(viewWithAccessibilityIdentifier: "recap.row.3.source")
                .find(ViewType.Button.self)
                .tap()
            #expect(opened == question.sourceUrl,
                    "the link must report its own question's source URL")
        }
    }

    @Test("no source URL → no source link, even expanded")
    func noSourceNoLink() async throws {
        let view = row(expanded: true, question: sourcelessQuestion())
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) {
                _ = try tree.find(viewWithAccessibilityIdentifier: "recap.row.3.source")
            }
        }
    }
}
