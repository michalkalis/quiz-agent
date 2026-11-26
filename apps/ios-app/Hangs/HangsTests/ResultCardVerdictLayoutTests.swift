//
//  ResultCardVerdictLayoutTests.swift
//  HangsTests
//
//  #248.2 (founder 2026-11-25) set the verdict words; #250 (founder
//  2026-11-26, variant A "your answer as the headline") made the player's own
//  answer the headline under a small verdict, the correct answer below it.
//  These contracts guard WHAT the player is told: the verdict word per
//  outcome, and whether their own answer is shown struck through, shown
//  plain, or not at all. The visible "Your answer" label is gone (#250): the
//  headline carries it as its accessibility label for VoiceOver.
//

@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@Suite("#248.2: result card layout, verdict as the headline")
@MainActor
struct ResultCardVerdictLayoutTests {
    private let question = Question(
        id: "q_salt", question: "Which mineral did Roman soldiers get part of their pay in?", type: .text,
        possibleAnswers: nil, difficulty: "medium", topic: "History", category: "history",
        sourceUrl: "https://en.wikipedia.org/wiki/Salt", sourceExcerpt: nil, mediaUrl: nil,
        imageSubtype: nil, explanation: "The word salary comes from it.", generatedBy: nil
    )

    private func viewModel(said: String, result: Evaluation.EvaluationResult, correct: String = "Soľ") -> QuizViewModel {
        let vm = QuizViewModel(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService(),
            analytics: MockAnalyticsClient()
        )
        vm.currentSession = Fixtures.makeActiveSession()
        let evaluation = Evaluation(userAnswer: said, result: result, points: result == .correct ? 1 : 0, correctAnswer: correct, questionId: "q_salt", explanation: nil)
        vm.quizState = .showingResult(question: question, evaluation: evaluation)
        return vm
    }

    @Test("each outcome has its own headline word: Wrong, Correct, Skipped", arguments: [
        (Evaluation.EvaluationResult.incorrect, "Wrong"),
        (.partiallyCorrect, "Wrong"),
        (.correct, "Correct"),
        (.skipped, "Skipped"),
    ])
    func verdictWord(result: Evaluation.EvaluationResult, word: String) async throws {
        let view = ResultView(viewModel: viewModel(said: result == .skipped ? "" : "Pepper", result: result))
        try await ViewHosting.host(view) {
            let verdict = try view.inspect().find(viewWithAccessibilityIdentifier: "result.verdict")
            #expect(try verdict.text().string() == word)
        }
    }

    @Test("a wrong answer is the headline, struck through, and VoiceOver calls it \"Your answer\"")
    func wrongAnswerIsStruck() async throws {
        let view = ResultView(viewModel: viewModel(said: "Pepper", result: .incorrect))
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let line = try tree.find(viewWithAccessibilityIdentifier: "result.said")
            #expect(try line.accessibilityLabel().string() == "Your answer")
            let said = try line.find(text: "Pepper")
            #expect(try said.attributes().isStrikethrough(), "a wrong answer is crossed out")
        }
    }

    @Test("a right answer worded differently is shown, not struck through")
    func differentlyWordedRightAnswerIsPlain() async throws {
        let view = ResultView(viewModel: viewModel(said: "solo", result: .correct))
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let line = try tree.find(viewWithAccessibilityIdentifier: "result.heard")
            #expect(try line.accessibilityLabel().string() == "Your answer")
            let said = try line.find(text: "solo")
            // isStrikethrough() throws when the text has no strikethrough modifier at all.
            #expect(((try? said.attributes().isStrikethrough()) ?? false) == false, "it counted, so nothing is crossed out")
        }
    }

    @Test("a right answer identical to the correct one (case, accents, spaces ignored) hides \"Your answer\"")
    func identicalRightAnswerHidesBlock() async throws {
        let view = ResultView(viewModel: viewModel(said: "  SOL ", result: .correct))
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) { try tree.find(text: "Your answer") }
            #expect(throws: (any Error).self) { try tree.find(viewWithAccessibilityIdentifier: "result.heard") }
        }
    }

    @Test("a skip has no \"Your answer\" block")
    func skipHidesBlock() async throws {
        let view = ResultView(viewModel: viewModel(said: "", result: .skipped))
        try await ViewHosting.host(view) {
            #expect(throws: (any Error).self) { try view.inspect().find(text: "Your answer") }
        }
    }

    @Test("the card carries no category chip or dot")
    func noCategoryOnTheCard() async throws {
        let view = ResultView(viewModel: viewModel(said: "Pepper", result: .incorrect))
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) { try tree.find(viewWithAccessibilityIdentifier: "question.category") }
            #expect(throws: (any Error).self) { try tree.find(text: "History") }
        }
    }
}
