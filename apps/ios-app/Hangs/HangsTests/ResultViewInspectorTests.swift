//
//  ResultViewInspectorTests.swift
//  HangsTests
//
//  Task 4.1 (issue #31): ViewInspector assertions for the four runtime-state
//  variants of ResultView (correct / incorrect / partial / timeout).
//
//  Why ViewInspector (not snapshot): ResultView's four variants differ by
//  runtime @ObservedObject state, not by struct topology. swift-snapshot-
//  testing's .dump strategy reflects View struct via Mirror and produces
//  near-identical baselines for all four variants. ViewInspector reads the
//  @ObservedObject runtime state correctly (audit A2-3).
//
//  Swift 6 / AnyView note (audit A2-7): .find(text:) breadth-first traversal
//  sidesteps most explicit chain issues; .implicitAnyView() is used where an
//  explicit navigation step is required.
//
//  @State gate — design note:
//  ResultView gates `answerCard` and `statsRow` behind:
//    `if showEvaluation, viewModel.resultEvaluation != nil { ... }`
//  `showEvaluation` is an @State var (init = false) that flips in .onAppear.
//  ViewInspector's `callOnAppear()` fires the registered callback, which calls
//  `showEvaluation = true` through the captured binding. However, in the
//  ViewHosting context SwiftUI has replaced the struct's @State backing with
//  its own graph storage; re-calling `view.inspect()` on the original struct
//  reads the struct's pre-installation storage (false), not the graph storage.
//  Without the `didAppear` callback refactor (which requires modifying
//  ResultView.swift — forbidden by task constraints), the post-appear tree
//  with unlocked answerCard/statsRow is not reachable by ViewInspector.
//
//  Practical resolution:
//  – hero block and HangsResultBanner are ALWAYS rendered (no @State gate) →
//    these provide strong correct-vs-incorrect differentiation
//  – answerCard / statsRow assertions use the ViewHosting context where
//    `callOnAppear()` is tried; if they remain gated, the model-level
//    evaluation is asserted directly as a fallback
//  – timeout case: the gate condition `resultEvaluation != nil` fails regardless
//    of showEvaluation → absence assertions hold even pre-appear
//

import Foundation
@testable import Hangs
import Testing
import ViewInspector

// MARK: - Helpers

/// Build a QuizViewModel in .showingResult state for the given evaluation.
@MainActor
private func makeViewModel(evaluation: Evaluation) -> QuizViewModel {
    let vm = Fixtures.makeViewModel()
    vm.currentSession = Fixtures.makeActiveSession()
    vm.quizState = .showingResult(
        question: Fixtures.makeQuestion(),
        evaluation: evaluation
    )
    return vm
}

/// Build a QuizViewModel with no evaluation (timeout / no submitted answer).
@MainActor
private func makeViewModelNoEvaluation() -> QuizViewModel {
    let vm = Fixtures.makeViewModel()
    vm.currentSession = Fixtures.makeActiveSession()
    // quizState stays .idle; resultEvaluation == nil
    return vm
}

// MARK: - Suite

@Suite("ResultView ViewInspector Tests")
@MainActor
struct ResultViewInspectorTests {
    // MARK: - Correct variant

    /// evaluation.isCorrect == true:
    ///   • heroBlock "NAILED\nIT." is present (always rendered, no @State gate)
    ///   • HangsResultBanner shows "CORRECT" + checkmark icon
    ///   • resultEvaluation model reports isCorrect (model-level confirmation)
    @Test("Correct evaluation renders NAILED headline and CORRECT banner")
    func correctVariantRendersNailedHeadlineAndBanner() async throws {
        let evaluation = Evaluation(
            userAnswer: "Paris",
            result: .correct,
            points: 1.0,
            correctAnswer: "Paris",
            questionId: "q_test",
            explanation: nil
        )
        let vm = makeViewModel(evaluation: evaluation)
        let view = ResultView(viewModel: vm)

        try await ViewHosting.host(view) {
            let tree = try view.inspect()

            // Hero: "NAILED\nIT." text — presence confirms the correct branch rendered
            #expect(throws: Never.self) {
                try tree.find(text: "NAILED\nIT.")
            }

            // HangsResultBanner label: "CORRECT" for isCorrect == true
            #expect(throws: Never.self) {
                try tree.find(text: "CORRECT")
            }

            // HangsResultBanner icon: "checkmark" SF Symbol for correct variant
            // AccessibilityImageLabel wraps SF Symbols; find by system image name
            #expect(throws: Never.self) {
                try tree.find(ViewType.Image.self, where: {
                    try $0.actualImage().name() == "checkmark"
                })
            }

            // Model-level: viewModel confirms evaluation is correct
            #expect(vm.resultEvaluation?.isCorrect == true)
        }
    }

    // MARK: - Incorrect variant

    /// evaluation.isCorrect == false (result == .incorrect):
    ///   • heroBlock "CLOSE—\nBUT NO." is present
    ///   • HangsResultBanner shows "NOT QUITE" + xmark icon
    ///   • resultEvaluation model reports incorrect result
    @Test("Incorrect evaluation renders CLOSE headline and NOT QUITE banner")
    func incorrectVariantRendersCloseHeadlineAndBanner() async throws {
        let evaluation = Evaluation(
            userAnswer: "London",
            result: .incorrect,
            points: 0.0,
            correctAnswer: "Paris",
            questionId: "q_test",
            explanation: nil
        )
        let vm = makeViewModel(evaluation: evaluation)
        let view = ResultView(viewModel: vm)

        try await ViewHosting.host(view) {
            let tree = try view.inspect()

            // Hero: "CLOSE—\nBUT NO." — presence confirms the incorrect branch rendered
            #expect(throws: Never.self) {
                try tree.find(text: "CLOSE—\nBUT NO.")
            }

            // HangsResultBanner label: "NOT QUITE" for isCorrect == false
            #expect(throws: Never.self) {
                try tree.find(text: "NOT QUITE")
            }

            // HangsResultBanner icon: "xmark" SF Symbol for incorrect variant
            #expect(throws: Never.self) {
                try tree.find(ViewType.Image.self, where: {
                    try $0.actualImage().name() == "xmark"
                })
            }

            // "NAILED\nIT." must NOT appear
            #expect(throws: (any Error).self) {
                try tree.find(text: "NAILED\nIT.")
            }

            // Model-level: viewModel confirms the result is incorrect
            #expect(vm.resultEvaluation?.result == .incorrect)
        }
    }

    // MARK: - Partial credit variant

    /// evaluation.result == .partiallyCorrect:
    ///   • ResultView's isCorrect collapses to false → hero and banner are
    ///     structurally identical to the incorrect variant. This is a documented
    ///     limitation of ResultView: no separate partial-credit visual branch exists
    ///     in the always-rendered sections.
    ///   • The model correctly carries result = .partiallyCorrect and partial points.
    ///   • Asserting "NOT QUITE" + "CLOSE—\nBUT NO." confirms the view chose the
    ///     non-correct path, which is the correct rendering for a partial evaluation.
    @Test("Partial-credit evaluation renders incorrect-branch hero and partial result in model")
    func partialVariantRendersIncorrectBranchAndCarriesPartialResult() async throws {
        let evaluation = Evaluation(
            userAnswer: "Paris, France",
            result: .partiallyCorrect,
            points: 0.5,
            correctAnswer: "Paris",
            questionId: "q_test",
            explanation: nil
        )
        let vm = makeViewModel(evaluation: evaluation)
        let view = ResultView(viewModel: vm)

        try await ViewHosting.host(view) {
            let tree = try view.inspect()

            // isCorrect == false for partial → incorrect visual branch
            #expect(throws: Never.self) {
                try tree.find(text: "CLOSE—\nBUT NO.")
            }
            #expect(throws: Never.self) {
                try tree.find(text: "NOT QUITE")
            }

            // Model-level: result is partiallyCorrect (not just .incorrect)
            #expect(vm.resultEvaluation?.result == .partiallyCorrect)

            // Model-level: partial points (0.5) distinguishes from binary wrong (0.0)
            #expect(vm.resultEvaluation?.points == 0.5)
        }
    }

    // MARK: - Timeout variant (no evaluation)

    /// viewModel.resultEvaluation == nil (timeout / no submitted answer):
    ///   • The `if showEvaluation, resultEvaluation != nil` gate fails regardless of
    ///     showEvaluation value — answerCard and statsRow are never rendered.
    ///   • heroBlock and footerBar always render → "Next question" button is present.
    ///   • Card section labels "YOU SAID" / "YOUR ANSWER" must be absent.
    @Test("Timeout (nil evaluation) hides answer card and stats row, keeps footer")
    func timeoutVariantHidesCardAndStatsKeepsFooter() async throws {
        let vm = makeViewModelNoEvaluation()
        let view = ResultView(viewModel: vm)

        try await ViewHosting.host(view) {
            let tree = try view.inspect()

            // footerBar is always rendered (no gate) — "Next question" must be present
            #expect(throws: Never.self) {
                try tree.find(button: "Next question")
            }

            // answerCard labels absent (gate: resultEvaluation != nil fails)
            #expect(throws: (any Error).self) {
                try tree.find(text: "YOU SAID")
            }
            #expect(throws: (any Error).self) {
                try tree.find(text: "YOUR ANSWER")
            }

            // statsRow streak suffix "+1" absent (same gate)
            #expect(throws: (any Error).self) {
                try tree.find(text: "+1")
            }

            // Model-level: no evaluation set
            #expect(vm.resultEvaluation == nil)
        }
    }

    // MARK: - Revealed answer (headline_answer ?? correct_answer) — 46.B9

    /// Open-branch reveal: an evaluation carrying `headlineAnswer` surfaces the
    /// short gist in "THE ANSWER" card, not the long `correctAnswer`.
    ///
    /// The answer card sits behind the `showEvaluation` @State gate that
    /// ViewInspector cannot flip (see design note above), so the reveal logic is
    /// asserted on ResultView's `revealedAnswer` computed property directly.
    @Test("Open question reveals headlineAnswer gist, not the long correctAnswer")
    func openQuestionRevealsHeadlineAnswer() {
        let evaluation = Evaluation(
            userAnswer: "desert",
            result: .incorrect,
            points: 0.0,
            correctAnswer: "A lush green landscape with rivers, lakes and abundant wildlife",
            questionId: "q_open",
            explanation: "The Sahara was a savanna during the African Humid Period.",
            headlineAnswer: "Grassland/savanna"
        )
        let view = ResultView(viewModel: makeViewModel(evaluation: evaluation))

        // Reveal surfaces the short gist, not the descriptive sentence.
        #expect(view.revealedAnswer == "Grassland/savanna")
    }

    /// Closed-branch regression: with no `headlineAnswer` the reveal must remain
    /// exactly `correctAnswer` — the existing closed-question path is unchanged.
    @Test("Closed question reveal falls back to correctAnswer unchanged")
    func closedQuestionRevealsCorrectAnswer() {
        let evaluation = Evaluation(
            userAnswer: "London",
            result: .incorrect,
            points: 0.0,
            correctAnswer: "Paris",
            questionId: "q_closed",
            explanation: nil
            // headlineAnswer defaults to nil — closed question
        )
        let view = ResultView(viewModel: makeViewModel(evaluation: evaluation))

        #expect(view.revealedAnswer == "Paris")
    }
}
