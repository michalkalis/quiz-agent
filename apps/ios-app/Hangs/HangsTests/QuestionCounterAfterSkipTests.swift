//
//  QuestionCounterAfterSkipTests.swift
//  HangsTests
//
//  Founder bug 2026-10-07: on "question 3/10" the player skipped, and the next
//  question read "2/10" — the skipped question's own result screen was one
//  short too. The counter was derived from the participant's answered count,
//  which a skip deliberately does not move (it is the scoring denominator).
//  The backend now sends `asked_count` (every served question, answered OR
//  skipped) and both quiz screens count from it.
//
//  The invariants a driver relies on when glancing at the counter:
//  - a question and its result screen show the SAME number, skip or not;
//  - the next question shows that number + 1;
//  - the counter never moves backwards.
//  Plus the deploy-order contract: an old backend without `asked_count` must
//  still decode and keep the old counter.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@MainActor
@Suite("Question counter survives a skip (asked_count)")
struct QuestionCounterAfterSkipTests {

    // MARK: - Helpers

    /// Session as the backend sends it: `answered` moves only on answers,
    /// `asked` on every served question.
    private func session(asked: Int, answered: Int, phase: String = "asking") -> QuizSession {
        Fixtures.session(answered: answered, phase: phase, askedCount: asked)
    }

    /// The skip's response: verdict for `skippedId`, plus — unless the set is
    /// over — the next question the backend already served (and counted).
    private func skipResponse(skippedId: String, next: Question?, session: QuizSession) -> QuizResponse {
        QuizResponse(
            success: true,
            message: "Input processed",
            session: session,
            currentQuestion: next,
            evaluation: Evaluation(
                userAnswer: "skipped",
                result: .skipped,
                points: 0.0,
                correctAnswer: "Paris",
                questionId: skippedId,
                explanation: nil
            ),
            feedbackReceived: ["skipped question"],
            audio: nil
        )
    }

    /// A quiz sitting on question 3 of 10 with two answered, mid-skip.
    private func viewModelOnThirdQuestion() -> QuizViewModel {
        let viewModel = QuizViewModel(
            networkService: Fixtures.makeFullMockNetwork(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService()
        )
        viewModel.currentSession = session(asked: 3, answered: 2)
        viewModel.currentQuestion = Fixtures.makeQuestion(id: "q3")
        viewModel.quizState = .askingQuestion
        return viewModel
    }

    private func counterText<V: View>(of view: V) async throws -> String {
        var text = ""
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            text = try tree.find(viewWithAccessibilityIdentifier: "question.counter").text().string()
        }
        return text
    }

    // MARK: - The bug

    @Test("after a skip, the result keeps the skipped question's number and the next question is +1")
    func skipKeepsNumberThenAdvancesByOne() async throws {
        let viewModel = viewModelOnThirdQuestion()
        #expect(viewModel.askedQuestionNumber == 3, "on screen: question 3")
        viewModel.quizState = .skipping

        // Backend: q3 skipped, q4 served → asked 4, answered still 2.
        await viewModel.handleQuizResponse(skipResponse(
            skippedId: "q3",
            next: Fixtures.makeQuestion(id: "q4"),
            session: session(asked: 4, answered: 2)
        ))
        #expect(viewModel.quizState.isShowingResult)
        // The pre-fix value here was 2 (answered count): the counter went backwards.
        #expect(viewModel.askedQuestionNumber == 3, "the skipped question's result is still question 3")
        #expect(try await counterText(of: ResultView(viewModel: viewModel)) == "3/10")

        await viewModel.proceedToNextQuestion()
        #expect(viewModel.currentQuestion?.id == "q4")
        #expect(viewModel.askedQuestionNumber == 4, "the next question is 3 + 1")
        #expect(try await counterText(of: QuestionView(viewModel: viewModel)) == "4/10")
        // Score semantics untouched: a skip is still not an answer.
        #expect(viewModel.questionsAnswered == 2)
    }

    @Test("skipping the last question shows 10/10 on its result, not 9/10")
    func skipOfLastQuestionKeepsItsNumber() async throws {
        let viewModel = viewModelOnThirdQuestion()
        viewModel.currentSession = session(asked: 10, answered: 9)
        viewModel.currentQuestion = Fixtures.makeQuestion(id: "q10")
        viewModel.quizState = .skipping

        // Nothing is served after the last question, so asked stays 10.
        await viewModel.handleQuizResponse(skipResponse(
            skippedId: "q10",
            next: nil,
            session: session(asked: 10, answered: 9, phase: "finished")
        ))

        #expect(viewModel.quizState.isShowingResult)
        #expect(viewModel.askedQuestionNumber == 10)
        #expect(try await counterText(of: ResultView(viewModel: viewModel)) == "10/10")
    }

    // MARK: - Deploy in any order

    @Test("a backend without asked_count keeps the old answered-count counter")
    func oldBackendFallsBackToAnsweredCount() throws {
        let viewModel = viewModelOnThirdQuestion()
        viewModel.currentSession = Fixtures.session(answered: 2) // no askedCount
        #expect(viewModel.askedQuestionNumber == nil, "nil routes the views to their pre-fix derivation")
    }

    @Test("asked_count is optional on the wire: absent decodes to nil, present decodes")
    func askedCountDecodesAdditively() throws {
        func decode(_ extra: String) throws -> QuizSession {
            let json = """
            {
              "session_id": "s1", "mode": "single", "phase": "asking",
              "max_questions": 10, "current_difficulty": "medium", "category": null,
              "language": "en", "participants": [],
              "expires_at": "2026-10-07T11:00:00Z", "created_at": "2026-10-07T10:00:00Z"\(extra)
            }
            """
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(QuizSession.self, from: Data(json.utf8))
        }
        #expect(try decode("").askedCount == nil)
        #expect(try decode(#", "asked_count": 4"#).askedCount == 4)
    }
}
