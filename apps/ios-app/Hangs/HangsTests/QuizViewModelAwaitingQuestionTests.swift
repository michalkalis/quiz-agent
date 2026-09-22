//
//  QuizViewModelAwaitingQuestionTests.swift
//  HangsTests
//
//  Issue #182: a custom pack is playable from its first persisted batch, so a
//  fast player can catch up with the generator mid-set. When that happens the
//  server grades the answer but has no next question yet (`awaiting_question`),
//  and the quiz must WAIT — visibly, and then continue on its own.
//
//  The regression these guard is the worst one available here: treating "no
//  next question" as "the set is over" ends a paid pack early, in the car,
//  with questions still being written for it.
//

import Foundation
@testable import Hangs
import Testing

@MainActor
@Suite("QuizViewModel awaiting next pack question (#182)")
struct QuizViewModelAwaitingQuestionTests {

    // MARK: - Helpers

    /// A graded answer whose response carries NO next question and the #182
    /// awaiting flag — exactly what the backend returns when the player has
    /// caught up with the generator.
    private func awaitingEvaluationResponse(sessionId: String = "test_session_123") -> QuizResponse {
        QuizResponse(
            success: true,
            message: "Input processed",
            session: Fixtures.makeActiveSession(id: sessionId), // phase stays "asking"
            currentQuestion: nil,
            evaluation: Evaluation(
                userAnswer: "4",
                result: .correct,
                points: 1.0,
                correctAnswer: "4",
                questionId: "q_001",
                explanation: nil
            ),
            feedbackReceived: [],
            audio: nil,
            awaitingQuestion: true
        )
    }

    /// Seeds a quiz that has just graded an answer with no next question ready,
    /// then advances — the exact path a player who outran the generator takes.
    private func advancedIntoWait(
        configure: (MockNetworkService) -> Void
    ) async -> (QuizViewModel, MockNetworkService) {
        let mockNetwork = Fixtures.makeFullMockNetwork(configure: configure)
        let viewModel = QuizViewModel(
            networkService: mockNetwork,
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService()
        )
        viewModel.awaitingQuestionPollIntervalSeconds = 0 // no wall-clock waiting in tests
        viewModel.currentSession = Fixtures.makeActiveSession()
        viewModel.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        viewModel.quizState = .processing

        await viewModel.handleQuizResponse(awaitingEvaluationResponse())
        await viewModel.proceedToNextQuestion()
        return (viewModel, mockNetwork)
    }

    // MARK: - Tests

    // The core #182 invariant: no next question + not finished + awaiting flag
    // must NEVER end the set. Before this the advance fell through to the
    // "more questions remain" branch with a nil question and dead-ended.
    @Test("a graded answer with awaiting_question parks the quiz in .awaitingQuestion, never .finished")
    func awaitingResponseDoesNotFinishTheQuiz() async {
        let (viewModel, mockNetwork) = await advancedIntoWait { mock in
            mock.nextQuestionResults = [.success(QuizResponse(
                success: true,
                message: "Still generating",
                session: Fixtures.makeActiveSession(),
                currentQuestion: nil,
                evaluation: nil,
                feedbackReceived: [],
                audio: nil,
                awaitingQuestion: true
            ))]
        }

        #expect(viewModel.quizState == .awaitingQuestion)
        #expect(viewModel.quizState != .finished)
        #expect(viewModel.currentQuestion == nil, "nothing may be shown as answerable while we wait")
        // And the client is actually polling for it, not sitting there forever.
        await pumpUntil({ mockNetwork.nextQuestionCallCount >= 1 }, turns: 500)
        #expect(mockNetwork.nextQuestionCallCount >= 1)
        await viewModel.endQuiz()
    }

    // The wait has to end by itself — a driver cannot tap anything to recover.
    @Test("a question that lands during the wait resumes the quiz at .askingQuestion")
    func landedQuestionResumesTheQuiz() async {
        let (viewModel, mockNetwork) = await advancedIntoWait { mock in
            mock.nextQuestionResults = [
                .success(QuizResponse(
                    success: true,
                    message: "Still generating",
                    session: Fixtures.makeActiveSession(),
                    currentQuestion: nil,
                    evaluation: nil,
                    feedbackReceived: [],
                    audio: nil,
                    awaitingQuestion: true
                )),
                .success(QuizResponse(
                    success: true,
                    message: "Question ready",
                    session: Fixtures.makeActiveSession(),
                    currentQuestion: Fixtures.makeQuestion(id: "q_002", text: "The pack caught up?"),
                    evaluation: nil,
                    feedbackReceived: [],
                    audio: nil
                )),
            ]
        }
        #expect(viewModel.quizState == .awaitingQuestion)

        await pumpUntil({ viewModel.quizState == .askingQuestion }, turns: 2000)

        #expect(viewModel.quizState == .askingQuestion)
        #expect(viewModel.currentQuestion?.id == "q_002")
        // The first poll answered "still awaiting", so the loop ran at least twice.
        #expect(mockNetwork.nextQuestionCallCount >= 2)
        await viewModel.endQuiz()
    }

    // The other honest ending: the pack closed and there is genuinely nothing
    // left. That is the recap/score screen, not an error and not a stuck wait.
    @Test("a finished session during the wait ends the set properly")
    func finishedDuringWaitEndsTheSet() async {
        let (viewModel, _) = await advancedIntoWait { mock in
            mock.nextQuestionResults = [.success(QuizResponse(
                success: true,
                message: "Quiz finished",
                session: Fixtures.makeActiveSession(phase: "finished"),
                currentQuestion: nil,
                evaluation: nil,
                feedbackReceived: [],
                audio: nil
            ))]
        }

        await pumpUntil({ viewModel.quizState == .finished }, turns: 2000)
        #expect(viewModel.quizState == .finished)
    }

    // A network outage mid-wait must surface, not spin silently forever: the
    // player has to be able to leave instead of staring at a calm panel that
    // will never resolve.
    @Test("a sustained run of poll failures surfaces an error instead of waiting forever")
    func sustainedPollFailuresSurfaceError() async {
        let (viewModel, mockNetwork) = await advancedIntoWait { mock in
            mock.nextQuestionResults = [.failure(NetworkError.invalidResponse)]
        }

        await pumpUntil({ viewModel.quizState.isError }, turns: 4000)
        #expect(viewModel.quizState.isError)
        #expect(mockNetwork.nextQuestionCallCount > QuizViewModel.maxAwaitingQuestionPollErrors)
    }

    // Leaving the quiz must take the poll with it — a surviving poll would
    // write a dead session's question onto whatever screen replaced it.
    @Test("quitting the quiz cancels the awaiting poll")
    func quitCancelsThePoll() async {
        let (viewModel, mockNetwork) = await advancedIntoWait { mock in
            mock.nextQuestionResults = [.success(QuizResponse(
                success: true,
                message: "Still generating",
                session: Fixtures.makeActiveSession(),
                currentQuestion: nil,
                evaluation: nil,
                feedbackReceived: [],
                audio: nil,
                awaitingQuestion: true
            ))]
        }
        await pumpUntil({ mockNetwork.nextQuestionCallCount >= 1 }, turns: 500)

        viewModel.resetToHome()
        await pumpUntil({ viewModel.quizState == .idle }, turns: 500)
        let callsAtQuit = mockNetwork.nextQuestionCallCount

        for _ in 0 ..< 200 { await Task.yield() }
        #expect(viewModel.quizState == .idle)
        #expect(mockNetwork.nextQuestionCallCount == callsAtQuit, "the poll must not outlive the quiz")
    }

    // MARK: - Response decoding contract

    @Test("awaiting_question defaults to false when the backend omits it")
    func awaitingQuestionDefaultsFalse() throws {
        let json = """
        {
          "success": true,
          "message": "ok",
          "session": {
            "session_id": "s1",
            "mode": "single",
            "phase": "asking",
            "max_questions": 10,
            "current_difficulty": "medium",
            "category": null,
            "language": "en",
            "participants": [],
            "expires_at": "2026-09-17T11:00:00Z",
            "created_at": "2026-09-17T10:00:00Z"
          },
          "current_question": null,
          "evaluation": null,
          "feedback_received": [],
          "audio": null
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(QuizResponse.self, from: Data(json.utf8))
        #expect(response.awaitingQuestion == false)
    }

    @Test("awaiting_question decodes true when the pack is still generating")
    func awaitingQuestionDecodesTrue() throws {
        let json = """
        {
          "success": true,
          "message": "ok",
          "session": {
            "session_id": "s1",
            "mode": "single",
            "phase": "asking",
            "max_questions": 10,
            "current_difficulty": "medium",
            "category": null,
            "language": "en",
            "participants": [],
            "expires_at": "2026-09-17T11:00:00Z",
            "created_at": "2026-09-17T10:00:00Z"
          },
          "current_question": null,
          "evaluation": null,
          "feedback_received": [],
          "audio": null,
          "awaiting_question": true
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(QuizResponse.self, from: Data(json.utf8))
        #expect(response.awaitingQuestion)
        // The session is NOT finished — this is a wait, not an ending.
        #expect(!response.session.isFinished)
    }
}
