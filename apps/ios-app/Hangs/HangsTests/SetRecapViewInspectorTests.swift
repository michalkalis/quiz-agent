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
        await vm.handleQuizResponse(response)
        let target = vm.recapEntries.count
        // The deferred advance is an untracked task — wait for it to settle
        // before mutating state for the next round.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while vm.quizState != .askingQuestion, ContinuousClock.now < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
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
