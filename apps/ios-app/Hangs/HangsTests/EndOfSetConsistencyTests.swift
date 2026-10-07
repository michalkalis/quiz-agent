//
//  EndOfSetConsistencyTests.swift
//  HangsTests
//
//  #188 G14 — the end-of-set screen showed a score of 1 "z 10" next to
//  "Správne 3, Úspešnosť 30 %". The headline reads the session score the
//  backend keeps; the counts and accuracy read the client's verdict tallies.
//  Against the real backend both come from the same verdicts (score += points,
//  a skip adds nothing); the UI-test mock returned one frozen response for
//  every answer, skip included. These tests pin that the numbers on the
//  screen never contradict each other when the session moves the way the
//  backend moves it, and that the UI-test app runs the mock that way.
//

import Foundation
@testable import Hangs
import Testing

@MainActor
@Suite("End-of-set numbers agree (#188 G14)")
struct EndOfSetConsistencyTests {
    /// Every number the complete screen shows, checked against the others.
    private func expectConsistent(_ summary: QuizCompleteSummary) {
        let undecided = summary.totalAnswered - summary.correctCount - summary.incorrectCount
        #expect(undecided >= 0, "correct + incorrect can never exceed answered")
        #expect(Double(summary.correctCount) <= summary.finalScore, "each correct answer is a full point of the score")
        #expect(summary.finalScore <= Double(summary.correctCount + undecided), "only partials add to the score beyond the correct answers")
        let expectedAccuracy = summary.totalQuestions > 0
            ? Double(summary.correctCount) / Double(summary.totalQuestions) * 100
            : 0
        #expect(summary.sessionAccuracyPercent == expectedAccuracy, "accuracy shares the set as its base")
    }

    private func play(_ inputs: [String], on vm: QuizViewModel, network: MockNetworkService) async throws {
        for input in inputs {
            vm.currentQuestion = Fixtures.makeQuestion(id: "q_preview_1")
            vm.quizState = .processing
            let response = try await network.submitTextInput(
                sessionId: "sess_preview_123", input: input, audio: false, questionId: "q_preview_1"
            )
            await vm.handleQuizResponse(response)
        }
    }

    @Test("answers and skips on a backend-like session: headline, counts and accuracy agree")
    func mixedSetAgrees() async throws {
        let (vm, network) = Fixtures.makeViewModelWithNetwork()
        network.tracksSessionScore = true
        network.mockTextInputResponse = QuizResponse.previewAnswerCorrect

        try await play(["Paris", "skip", "Paris", "skip", "Paris"], on: vm, network: network)

        let summary = CompletionView(viewModel: vm).summary
        #expect(summary.displayScore == "3")
        #expect(summary.correctCount == 3)
        #expect(summary.totalQuestions == 10)
        #expect(summary.sessionAccuracyPercent == 30)
        expectConsistent(summary)
    }

    @Test("a skip moves no number on the screen")
    func skipChangesNothing() async throws {
        let (vm, network) = Fixtures.makeViewModelWithNetwork()
        network.tracksSessionScore = true
        network.mockTextInputResponse = QuizResponse.previewAnswerCorrect

        try await play(["skip", "skip"], on: vm, network: network)

        let summary = CompletionView(viewModel: vm).summary
        #expect(summary.finalScore == 0)
        #expect(summary.correctCount == 0)
        #expect(summary.totalAnswered == 0)
        expectConsistent(summary)
    }

    // The screenshot came from the `--ui-test` app: its mock must move the
    // session like the backend, or the end-of-set screen can't be judged.
    @Test("the UI-test app's network mock keeps backend-like session totals")
    func uiTestMockTracksScore() throws {
        let network = try #require(UITestSupport.makeMockServices().network as? MockNetworkService)
        #expect(network.tracksSessionScore)
    }
}
