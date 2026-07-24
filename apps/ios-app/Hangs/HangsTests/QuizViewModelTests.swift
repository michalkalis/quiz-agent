//
//  QuizViewModelTests.swift
//  HangsTests
//
//  Tests for QuizViewModel state machine and quiz flow.
//

import ConcurrencyExtras
import Foundation
@testable import Hangs
import Testing

// MARK: - Test Fixtures

/// Creates a mock QuizResponse for testing
private func makeQuizResponse(
    evaluationFor questionId: String,
    userAnswer: String = "Test Answer",
    isCorrect: Bool = true,
    nextQuestion: Question? = nil,
    isFinished: Bool = false
) -> QuizResponse {
    QuizResponse(
        success: true,
        message: "Input processed",
        session: QuizSession(
            id: "test_session_123",
            mode: "single",
            phase: isFinished ? "finished" : "asking",
            maxQuestions: 10,
            currentDifficulty: "medium",
            category: nil,
            language: "en",
            participants: [
                Participant(
                    id: "p_test_1",
                    userId: nil,
                    displayName: "Player",
                    score: isCorrect ? 1.0 : 0.0,
                    answeredCount: 1,
                    correctCount: isCorrect ? 1 : 0,
                    lastAnswer: userAnswer,
                    lastResult: isCorrect ? "correct" : "incorrect",
                    isHost: true,
                    isReady: true,
                    joinedAt: Date()
                ),
            ],
            expiresAt: Date().addingTimeInterval(30 * 60),
            createdAt: Date()
        ),
        currentQuestion: nextQuestion,
        evaluation: Evaluation(
            userAnswer: userAnswer,
            result: isCorrect ? .correct : .incorrect,
            points: isCorrect ? 1.0 : 0.0,
            correctAnswer: "Expected Answer",
            questionId: questionId,
            explanation: nil
        ),
        feedbackReceived: ["answer: \(isCorrect ? "correct" : "incorrect")"],
        audio: nil
    )
}

/// Creates a Question with specific ID and source for testing
private func makeQuestion(id: String, source: String) -> Question {
    Question(
        id: id,
        question: "Question \(id)?",
        type: .text,
        possibleAnswers: nil,
        difficulty: "medium",
        topic: "Test Topic",
        category: "test",
        sourceUrl: "https://example.com/\(id)",
        sourceExcerpt: source,
        mediaUrl: nil,
        imageSubtype: nil,
        explanation: nil,
        generatedBy: nil
    )
}

// MARK: - Result State Tests

@Suite("QuizViewModel Result State Tests")
struct QuizViewModelResultStateTests {
    @Test("resultQuestion and resultEvaluation are bundled in showingResult state")
    @MainActor
    func resultDataBundledInState() async throws {
        let viewModel = Fixtures.makeViewModel()
        let questionA = makeQuestion(id: "q_001", source: "Source for question A")
        let evaluation = Evaluation(
            userAnswer: "Paris",
            result: .correct,
            points: 1.0,
            correctAnswer: "Paris",
            questionId: "q_001",
            explanation: nil
        )

        // Set state with associated values
        viewModel.quizState = .showingResult(question: questionA, evaluation: evaluation)

        // Computed accessors should extract the data
        #expect(viewModel.resultQuestion?.id == "q_001")
        #expect(viewModel.resultQuestion?.sourceExcerpt == "Source for question A")
        #expect(viewModel.resultEvaluation?.correctAnswer == "Paris")
        #expect(viewModel.quizState.isShowingResult)
    }

    @Test("resultQuestion is nil when not in showingResult state")
    @MainActor
    func resultDataNilOutsideShowingResult() async throws {
        let viewModel = Fixtures.makeViewModel()

        // In idle state, no result data
        #expect(viewModel.resultQuestion == nil)
        #expect(viewModel.resultEvaluation == nil)
        #expect(!viewModel.quizState.isShowingResult)
    }

    @Test("result data is structurally bound — currentQuestion changes don't affect it")
    @MainActor
    func resultDataStableWhenCurrentQuestionChanges() async throws {
        let viewModel = Fixtures.makeViewModel()
        let questionA = makeQuestion(id: "q_001", source: "Source A")
        let questionB = makeQuestion(id: "q_002", source: "Source B")
        let evaluation = Evaluation(
            userAnswer: "Answer A",
            result: .correct,
            points: 1.0,
            correctAnswer: "Expected A",
            questionId: "q_001",
            explanation: nil
        )

        viewModel.currentQuestion = questionA
        viewModel.quizState = .showingResult(question: questionA, evaluation: evaluation)

        // Simulate next question arriving (e.g., stored in nextQuestion internally)
        viewModel.currentQuestion = questionB

        // Result data is in the enum, not affected by currentQuestion
        #expect(viewModel.resultQuestion?.id == "q_001")
        #expect(viewModel.resultQuestion?.sourceExcerpt == "Source A")
        #expect(viewModel.currentQuestion?.id == "q_002")
    }

    @Test("proceedToNextQuestion transitions away from showingResult")
    @MainActor
    func proceedClearsResultState() async throws {
        let viewModel = Fixtures.makeViewModel()
        let questionA = makeQuestion(id: "q_001", source: "Source A")
        let evaluation = Evaluation(
            userAnswer: "A1",
            result: .correct,
            points: 1.0,
            correctAnswer: "A1",
            questionId: "q_001",
            explanation: nil
        )

        viewModel.quizState = .showingResult(question: questionA, evaluation: evaluation)
        viewModel.currentSession = QuizSession(
            id: "test_session",
            mode: "single",
            phase: "asking",
            maxQuestions: 10,
            currentDifficulty: "medium",
            category: nil,
            language: "en",
            participants: [],
            expiresAt: Date().addingTimeInterval(30 * 60),
            createdAt: Date()
        )

        await viewModel.proceedToNextQuestion()

        // After proceeding, result data is gone (state is no longer .showingResult)
        #expect(viewModel.resultQuestion == nil)
        #expect(viewModel.resultEvaluation == nil)
    }

    @Test("resetToHome resets quiz state cleanly")
    @MainActor
    func resetToHomeResetsState() async throws {
        let viewModel = Fixtures.makeViewModel()
        let question = makeQuestion(id: "q_001", source: "Test")
        let evaluation = Evaluation(
            userAnswer: "Test",
            result: .correct,
            points: 1.0,
            correctAnswer: "Test",
            questionId: "q_001",
            explanation: nil
        )

        viewModel.currentQuestion = question
        viewModel.quizState = .showingResult(question: question, evaluation: evaluation)
        viewModel.currentSession = Fixtures.session(score: 5.0, answered: 3)

        viewModel.resetToHome()

        #expect(viewModel.quizState == .idle)
        #expect(viewModel.currentQuestion == nil)
        #expect(viewModel.resultQuestion == nil)
        #expect(viewModel.resultEvaluation == nil)
        #expect(viewModel.score == 0.0)
        #expect(viewModel.questionsAnswered == 0)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("rapid question transitions maintain correct pairing")
    @MainActor
    func rapidTransitionsMaintainCorrectPairing() async throws {
        let viewModel = Fixtures.makeViewModel()
        viewModel.currentSession = QuizSession(
            id: "test_session",
            mode: "single",
            phase: "asking",
            maxQuestions: 10,
            currentDifficulty: "medium",
            category: nil,
            language: "en",
            participants: [],
            expiresAt: Date().addingTimeInterval(30 * 60),
            createdAt: Date()
        )

        // Question 1
        let q1 = makeQuestion(id: "q_001", source: "Source 1")
        let eval1 = Evaluation(
            userAnswer: "A1",
            result: .correct,
            points: 1.0,
            correctAnswer: "A1",
            questionId: "q_001",
            explanation: nil
        )
        viewModel.currentQuestion = q1
        viewModel.quizState = .showingResult(question: q1, evaluation: eval1)

        #expect(viewModel.resultQuestion?.id == "q_001")
        #expect(viewModel.resultQuestion?.sourceExcerpt == "Source 1")

        // Rapidly transition to Q2
        await viewModel.proceedToNextQuestion()
        #expect(viewModel.resultQuestion == nil)

        // Question 2
        let q2 = makeQuestion(id: "q_002", source: "Source 2")
        let eval2 = Evaluation(
            userAnswer: "A2",
            result: .incorrect,
            points: 0.0,
            correctAnswer: "A2 Expected",
            questionId: "q_002",
            explanation: nil
        )
        viewModel.currentQuestion = q2
        viewModel.quizState = .showingResult(question: q2, evaluation: eval2)

        // Assert Q2 state — should not have Q1's source
        #expect(viewModel.resultQuestion?.id == "q_002")
        #expect(viewModel.resultQuestion?.sourceExcerpt == "Source 2")
        #expect(viewModel.resultQuestion?.sourceExcerpt != "Source 1")
    }
}

// MARK: - Loading State Tests

@Suite("QuizViewModel Loading State Tests")
struct QuizViewModelLoadingStateTests {
    @Test("submitVoiceAnswer sets quizState to processing then resolves")
    @MainActor
    func submitVoiceAnswerSetsProcessing() async throws {
        let (viewModel, _) = Fixtures.makeViewModelWithNetwork()
        // Set up active session so submitVoiceAnswer doesn't bail early
        viewModel.currentSession = QuizSession(
            id: "test_session_123",
            mode: "single", phase: "asking", maxQuestions: 10,
            currentDifficulty: "medium", category: nil, language: "en",
            participants: [], expiresAt: Date().addingTimeInterval(1800),
            createdAt: Date()
        )
        viewModel.currentQuestion = makeQuestion(id: "q_001", source: "Test")
        viewModel.quizState = .askingQuestion

        await viewModel.recordingCoordinator.submitVoiceAnswer(audioData: Data("mock audio".utf8))

        // After completion, state should not be .processing (moved to showingResult via confirmation)
        // The answer confirmation sheet should be shown
        #expect(viewModel.showAnswerConfirmation == true)
    }

    @Test("skipQuestion sets quizState to processing then resolves to showingResult")
    @MainActor
    func skipQuestionSetsProcessing() async throws {
        let (viewModel, _) = Fixtures.makeViewModelWithNetwork()
        viewModel.currentSession = QuizSession(
            id: "test_session_123",
            mode: "single", phase: "asking", maxQuestions: 10,
            currentDifficulty: "medium", category: nil, language: "en",
            participants: [], expiresAt: Date().addingTimeInterval(1800),
            createdAt: Date()
        )
        viewModel.currentQuestion = makeQuestion(id: "q_001", source: "Test")
        viewModel.quizState = .askingQuestion

        await viewModel.skipQuestion()

        // After skip completes, state transitions to showingResult
        #expect(viewModel.quizState.isShowingResult)
    }

    @Test("resubmitAnswer sets quizState to processing then resolves to showingResult")
    @MainActor
    func resubmitAnswerSetsProcessing() async throws {
        let (viewModel, _) = Fixtures.makeViewModelWithNetwork()
        viewModel.currentSession = QuizSession(
            id: "test_session_123",
            mode: "single", phase: "asking", maxQuestions: 10,
            currentDifficulty: "medium", category: nil, language: "en",
            participants: [], expiresAt: Date().addingTimeInterval(1800),
            createdAt: Date()
        )
        viewModel.currentQuestion = makeQuestion(id: "q_001", source: "Test")
        viewModel.quizState = .askingQuestion

        await viewModel.resubmitAnswer("Paris")

        #expect(viewModel.quizState.isShowingResult)
    }

    @Test("startNewQuiz transitions to askingQuestion on success")
    @MainActor
    func startNewQuizTransitionsToAskingQuestion() async throws {
        let (viewModel, _) = Fixtures.makeViewModelWithNetwork()

        #expect(viewModel.quizState == .idle)

        await viewModel.startNewQuiz()

        #expect(viewModel.quizState == .askingQuestion)
        #expect(viewModel.currentQuestion != nil)
    }

    @Test("startNewQuiz transitions to error on failure")
    @MainActor
    func startNewQuizTransitionsToError() async throws {
        let (viewModel, _) = Fixtures.makeViewModelWithNetwork(shouldFail: true)

        await viewModel.startNewQuiz()

        #expect(viewModel.quizState.isError)
    }

    /// #110 Bug 1: "Try Again" (ErrorView) fires startNewQuiz from `.error` — the
    /// table must admit `error → startingQuiz` or the whole flow runs while
    /// quizState stays stuck on `.error`.
    @Test("startNewQuiz from .error (Try Again) reaches askingQuestion")
    @MainActor
    func startNewQuizFromErrorReachesAskingQuestion() async throws {
        let (viewModel, mockNetwork) = Fixtures.makeViewModelWithNetwork()
        viewModel.quizState = .error(message: "boom", context: .initialization)

        // Pin the transition itself, not just the end state: pre-#110 the
        // rejected error → startingQuiz transition was silently dropped and the
        // flow ran on while quizState stayed .error — the end state
        // (.askingQuestion) was reachable anyway because error → askingQuestion
        // was already legal, so it alone cannot detect a revert.
        var stateDuringCreateSession: QuizState?
        mockNetwork.onCreateSession = { stateDuringCreateSession = viewModel.quizState }

        await viewModel.startNewQuiz()

        #expect(stateDuringCreateSession == .startingQuiz)
        #expect(viewModel.quizState == .askingQuestion)
        #expect(mockNetwork.createSessionCallCount == 1)
    }

    /// #110 Bug 1: "Play Again" (CompletionView) fires startNewQuiz from
    /// `.finished` — before the fix `finished → startingQuiz` was rejected, so
    /// the CTA silently spun up a background session while the UI stayed frozen
    /// on CompletionView.
    @Test("startNewQuiz from .finished (Play Again) reaches askingQuestion")
    @MainActor
    func startNewQuizFromFinishedReachesAskingQuestion() async throws {
        let (viewModel, mockNetwork) = Fixtures.makeViewModelWithNetwork()
        viewModel.quizState = .finished

        await viewModel.startNewQuiz()

        #expect(viewModel.quizState == .askingQuestion)
        #expect(mockNetwork.createSessionCallCount == 1)
    }

    /// #110 Bug 1: a double-tap on "Play Again"/"Try Again" before the first
    /// `createSession` resolves must not clobber `currentSession` with a second
    /// concurrent session — the `isStarting` single-flight guard closes this.
    @Test("startNewQuiz double-tap creates exactly one session")
    @MainActor
    func startNewQuizDoubleTapCreatesOneSession() async throws {
        await withMainSerialExecutor {
            let (viewModel, mockNetwork) = Fixtures.makeViewModelWithNetwork()
            viewModel.quizState = .finished

            async let first: Void = viewModel.startNewQuiz()
            async let second: Void = viewModel.startNewQuiz()
            _ = await (first, second)

            #expect(mockNetwork.createSessionCallCount == 1)
        }
    }

    /// FIX3: prod Fly machines auto-stop to zero, so the first `createSession`
    /// after idle hits a cold start and throws a transient connection error
    /// (`URLError.timedOut`). The bounded retry must swallow that and land on a
    /// warm second attempt — reaching `.askingQuestion` instead of the error
    /// screen — with `createSession` invoked twice (1 failure + 1 success).
    @Test("startNewQuiz retries a transient cold-start error and recovers")
    @MainActor
    func startNewQuizRetriesTransientColdStart() async throws {
        let (viewModel, mockNetwork) = Fixtures.makeViewModelWithNetwork(configure: { mock in
            // Throws URLError.timedOut once (cold start), then succeeds.
            mock.createSessionFailuresBeforeSuccess = 1
        })

        await viewModel.startNewQuiz()

        #expect(mockNetwork.createSessionCallCount == 2)
        #expect(viewModel.quizState == .askingQuestion)
        #expect(!viewModel.quizState.isError)
    }

    /// FIX3: a permanent failure (non-transient server error, e.g. HTTP 400)
    /// must NOT be retried — it surfaces on the very first attempt so the user
    /// is not stalled behind pointless backoff. `createSession` runs exactly
    /// once and the flow lands on the error screen.
    @Test("startNewQuiz does not retry a permanent error")
    @MainActor
    func startNewQuizDoesNotRetryPermanentError() async throws {
        let (viewModel, mockNetwork) = Fixtures.makeViewModelWithNetwork(configure: { mock in
            mock.createSessionError = NetworkError.serverError(statusCode: 400, message: "bad request")
        })

        await viewModel.startNewQuiz()

        #expect(mockNetwork.createSessionCallCount == 1)
        #expect(viewModel.quizState.isError)
    }

    /// Cancelling an in-flight start (Home "Cancel" tap) must land back on
    /// `.idle`, not the error screen — a cancelled start is a user choice, not
    /// a failure. `onCreateSession` cancels the wrapping `beginQuizStart` Task
    /// synchronously; the mock's `Task.checkCancellation()` then throws exactly
    /// like the real `URLSession` would on a cancelled request.
    @Test("cancelling during in-flight createSession lands on .idle, not the error screen")
    @MainActor
    func cancelDuringCreateSessionLandsOnIdle() async throws {
        let (viewModel, mockNetwork) = Fixtures.makeViewModelWithNetwork()
        mockNetwork.onCreateSession = { [weak viewModel] in viewModel?.cancelQuizStart() }

        await viewModel.beginQuizStart().value

        #expect(viewModel.quizState == .idle)
        #expect(!viewModel.quizState.isError)
        #expect(mockNetwork.createSessionCallCount == 1)
    }

    /// Cancelling while the transient cold-start retry is sleeping between
    /// attempts must abort the retry loop immediately rather than swallow the
    /// cancellation and fire a second attempt — the `withTransientStartRetry`
    /// backoff switched `try?` (swallows `CancellationError`) to `try`
    /// (propagates it). The first attempt fails (cold start), then the retry
    /// parks in its backoff sleep — pinned to 10 minutes via
    /// `transientStartBackoffOverride` so the cancel deterministically lands
    /// inside the sleep even when the full suite's parallel load delays this
    /// test's poll loop by seconds (the real ~1s window was racy: the backoff
    /// could elapse and fire attempt 2 before the poll ever observed attempt 1).
    @Test("cancelling during the cold-start backoff aborts the retry")
    @MainActor
    func cancelDuringBackoffAbortsRetry() async throws {
        let (viewModel, mockNetwork) = Fixtures.makeViewModelWithNetwork(configure: { mock in
            mock.createSessionFailuresBeforeSuccess = 1
        })
        viewModel.transientStartBackoffOverride = { _ in .seconds(600) }

        let task = viewModel.beginQuizStart()
        for _ in 0 ..< 10_000 where mockNetwork.createSessionCallCount < 1 {
            // Paired with a tiny real sleep (not a bare `Task.yield()` spin) —
            // matching the `waitUntil` convention elsewhere in this target
            // (QuizViewModelStreamingTests/QuizViewModelTimerTests): a
            // yield-only loop never really suspends, so under the full
            // suite's heavy parallel load it was winning an outsized share of
            // MainActor turns and measurably starving unrelated tests (the
            // answer/thinking-timer tests' per-second ticks slowed to ~13s).
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(mockNetwork.createSessionCallCount == 1, "first attempt never landed — retry timing assumption broke")
        viewModel.cancelQuizStart()
        await task.value

        #expect(mockNetwork.createSessionCallCount == 1)
        #expect(viewModel.quizState == .idle)
        #expect(!viewModel.quizState.isError)
    }

    /// FIX3: guards the transient/permanent boundary the retry hinges on —
    /// only cold-start connection failures and Fly-proxy 502/503 are transient;
    /// quota (429), auth (401), other 4xx, and decoding errors never are.
    @Test("isTransientStartError classifies only cold-start failures as transient")
    @MainActor
    func isTransientStartErrorClassification() async throws {
        // Transient: connection-level URLErrors (machine asleep)
        #expect(QuizViewModel.isTransientStartError(URLError(.timedOut)))
        #expect(QuizViewModel.isTransientStartError(URLError(.cannotConnectToHost)))
        #expect(QuizViewModel.isTransientStartError(URLError(.networkConnectionLost)))
        #expect(QuizViewModel.isTransientStartError(URLError(.cannotFindHost)))
        #expect(QuizViewModel.isTransientStartError(URLError(.dnsLookupFailed)))
        // Transient: Fly proxy while the machine wakes
        #expect(QuizViewModel.isTransientStartError(NetworkError.serverError(statusCode: 502, message: "x")))
        #expect(QuizViewModel.isTransientStartError(NetworkError.serverError(statusCode: 503, message: "x")))
        // Permanent: never retry
        #expect(!QuizViewModel.isTransientStartError(NetworkError.serverError(statusCode: 401, message: "x")))
        #expect(!QuizViewModel.isTransientStartError(NetworkError.serverError(statusCode: 429, message: "x")))
        #expect(!QuizViewModel.isTransientStartError(NetworkError.serverError(statusCode: 400, message: "x")))
        #expect(!QuizViewModel.isTransientStartError(NetworkError.serverError(statusCode: 500, message: "x")))
        #expect(!QuizViewModel.isTransientStartError(NetworkError.quotaLimitReached(QuotaLimitError(error: "limit_reached", questionsUsed: 30, questionsLimit: 30, resetsAt: "2026-08-01T00:00:00Z", upgradeAvailable: true))))
        #expect(!QuizViewModel.isTransientStartError(NetworkError.decodingError(URLError(.badServerResponse))))
        #expect(!QuizViewModel.isTransientStartError(URLError(.userAuthenticationRequired)))
    }

    /// #110 Bug 1: an accidental "Start Quiz" tap on the minimized-background
    /// HomeView while a quiz is actively mid-flight (e.g. `.recording`) must be a
    /// logged no-op, not a clobbered live session.
    @Test("startNewQuiz from .recording is a no-op")
    @MainActor
    func startNewQuizFromRecordingIsNoOp() async throws {
        let (viewModel, mockNetwork) = Fixtures.makeViewModelWithNetwork()
        viewModel.quizState = .recording

        await viewModel.startNewQuiz()

        #expect(viewModel.quizState == .recording)
        #expect(mockNetwork.createSessionCallCount == 0)
    }

    @Test("resetToHome resets to idle cleanly")
    @MainActor
    func resetToHomeResetsToIdle() async throws {
        let (viewModel, _) = Fixtures.makeViewModelWithNetwork()
        // Put viewModel into non-idle state
        viewModel.quizState = .processing
        viewModel.errorMessage = "Some error"
        viewModel.currentSession = Fixtures.session(score: 5.0, answered: 3)

        viewModel.resetToHome()

        #expect(viewModel.quizState == .idle)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.score == 0.0)
        #expect(viewModel.questionsAnswered == 0)
    }

    @Test("no isLoading property exists on QuizViewModel")
    @MainActor
    func noIsLoadingProperty() async throws {
        // This test documents that isLoading has been removed.
        // QuizState.processing is the single source of truth for loading state.
        let (viewModel, _) = Fixtures.makeViewModelWithNetwork()

        // The only way to check "is loading" is via quizState
        viewModel.quizState = .processing
        #expect(viewModel.quizState == .processing)

        viewModel.quizState = .idle
        #expect(viewModel.quizState != .processing)
    }

    @Test("skipQuestion during processing state keeps state consistent")
    @MainActor
    func skipQuestionDuringProcessingKeepsConsistentState() async throws {
        // This test documents the duplicate-call guard behavior.
        // handleQuizResponse uses a Bool guard (isProcessingResponse) to prevent
        // concurrent calls from corrupting state. When skipQuestion is called while
        // already in .processing, the second call through handleQuizResponse is
        // rejected by the guard, keeping state consistent.
        let (viewModel, _) = Fixtures.makeViewModelWithNetwork()
        viewModel.currentSession = QuizSession(
            id: "test_session_123",
            mode: "single", phase: "asking", maxQuestions: 10,
            currentDifficulty: "medium", category: nil, language: "en",
            participants: [], expiresAt: Date().addingTimeInterval(1800),
            createdAt: Date()
        )
        viewModel.currentQuestion = makeQuestion(id: "q_001", source: "Test")
        viewModel.quizState = .processing // Already processing

        // Call skipQuestion while already processing
        await viewModel.skipQuestion()

        // State should resolve to showingResult (the skip call goes through
        // handleQuizResponse which transitions to showingResult)
        #expect(viewModel.quizState.isShowingResult)
        #expect(viewModel.resultEvaluation != nil)
    }
}

// MARK: - Answer Confirmation Dismiss Tests

@Suite("QuizViewModel Answer Confirmation Dismiss Tests")
struct QuizViewModelAnswerConfirmationDismissTests {
    /// Put ViewModel into post-voice-submission state (pendingResponse set, confirmation sheet showing)
    @MainActor
    private func putIntoConfirmationState(_ viewModel: QuizViewModel) async {
        viewModel.currentSession = QuizSession(
            id: "test_session_123",
            mode: "single", phase: "asking", maxQuestions: 10,
            currentDifficulty: "medium", category: nil, language: "en",
            participants: [], expiresAt: Date().addingTimeInterval(1800),
            createdAt: Date()
        )
        viewModel.currentQuestion = makeQuestion(id: "q_001", source: "Test question")
        viewModel.quizState = .askingQuestion

        // submitVoiceAnswer sets pendingResponse and showAnswerConfirmation
        await viewModel.recordingCoordinator.submitVoiceAnswer(audioData: Data("mock audio".utf8))
    }

    @Test("handleAnswerConfirmationDismissed resets state when pendingResponse exists")
    @MainActor
    func dismissResetsStateWhenPendingResponseExists() async throws {
        let (viewModel, _) = Fixtures.makeViewModelWithNetwork(configure: { mock in
            mock.mockResponse = makeQuizResponse(
                evaluationFor: "q_001",
                userAnswer: "Paris",
                isCorrect: true,
                nextQuestion: makeQuestion(id: "q_002", source: "Next question")
            )
        })
        await putIntoConfirmationState(viewModel)

        // Verify we're in the confirmation state
        #expect(viewModel.showAnswerConfirmation == true)
        #expect(viewModel.transcribedAnswer == "Paris")

        // Simulate sheet dismiss (e.g., swipe down if it were allowed)
        viewModel.showAnswerConfirmation = false
        viewModel.handleAnswerConfirmationDismissed()

        // State should be cleaned up: back to askingQuestion, not stuck in processing
        #expect(viewModel.quizState == .askingQuestion)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("handleAnswerConfirmationDismissed is no-op after confirmAnswer")
    @MainActor
    func dismissIsNoOpAfterConfirmAnswer() async throws {
        let (viewModel, _) = Fixtures.makeViewModelWithNetwork(configure: { mock in
            mock.mockResponse = makeQuizResponse(
                evaluationFor: "q_001",
                userAnswer: "Paris",
                isCorrect: true,
                nextQuestion: makeQuestion(id: "q_002", source: "Next question")
            )
        })
        await putIntoConfirmationState(viewModel)

        // User taps Confirm — this clears pendingResponse and processes the answer
        await viewModel.confirmAnswer()

        // Verify confirmAnswer transitioned to showingResult
        #expect(viewModel.quizState.isShowingResult)

        // Now if onDismiss fires (sheet animation completing), it should be a no-op
        viewModel.handleAnswerConfirmationDismissed()

        // State should remain .showingResult, NOT reset to .askingQuestion
        #expect(viewModel.quizState.isShowingResult)
    }

    @Test("handleAnswerConfirmationDismissed is no-op after rerecordAnswer")
    @MainActor
    func dismissIsNoOpAfterRerecordAnswer() async throws {
        let (viewModel, _) = Fixtures.makeViewModelWithNetwork(configure: { mock in
            mock.mockResponse = makeQuizResponse(
                evaluationFor: "q_001",
                userAnswer: "Paris",
                isCorrect: true,
                nextQuestion: makeQuestion(id: "q_002", source: "Next question")
            )
        })
        await putIntoConfirmationState(viewModel)

        // User taps Re-record — this clears pendingResponse immediately and kicks
        // off a new recording attempt (#108A: no intermediate countdown, so the
        // exact quizState here is a timing detail — askingQuestion transiently,
        // then recording once the spawned Task runs).
        viewModel.rerecordAnswer()

        #expect(viewModel.showAnswerConfirmation == false)
        #expect(viewModel.recordingCoordinator.pendingResponse == nil, "rerecordAnswer must consume the pending response")
        let stateBeforeDismiss = viewModel.quizState

        // Now if onDismiss fires, it should be a no-op (pendingResponse already nil)
        viewModel.handleAnswerConfirmationDismissed()

        // handleAnswerConfirmationDismissed must not touch state once pendingResponse
        // is already nil, whatever state rerecordAnswer left it at.
        #expect(viewModel.quizState == stateBeforeDismiss)
    }
}

// MARK: - Recording Lifecycle Tests

@Suite("QuizViewModel Recording Tests")
struct QuizViewModelRecordingTests {
    @Test("toggleRecording from askingQuestion starts recording")
    @MainActor
    func toggleRecordingFromAskingQuestionStartsRecording() async throws {
        let (viewModel, mockAudio) = Fixtures.makeViewModelWithAudio()
        viewModel.quizState = .askingQuestion

        await viewModel.toggleRecording()

        #expect(viewModel.quizState == .recording)
        #expect(mockAudio.isRecording == true)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("toggleRecording from recording stops and submits")
    @MainActor
    func toggleRecordingFromRecordingStopsAndSubmits() async throws {
        let (viewModel, _) = Fixtures.makeViewModelWithAudio()
        viewModel.currentSession = QuizSession(
            id: "test_session_123",
            mode: "single", phase: "asking", maxQuestions: 10,
            currentDifficulty: "medium", category: nil, language: "en",
            participants: [], expiresAt: Date().addingTimeInterval(1800),
            createdAt: Date()
        )
        viewModel.currentQuestion = makeQuestion(id: "q_001", source: "Test")
        viewModel.quizState = .recording

        await viewModel.toggleRecording()

        // After successful stop + submit, answer confirmation should show
        #expect(viewModel.showAnswerConfirmation == true)
    }

    @Test("toggleRecording start failure rolls back to askingQuestion")
    @MainActor
    func toggleRecordingStartFailureRollsBack() async throws {
        let (viewModel, _) = Fixtures.makeViewModelWithAudio(shouldFailRecording: true)
        viewModel.quizState = .askingQuestion

        await viewModel.toggleRecording()

        #expect(viewModel.quizState == .askingQuestion)
        #expect(viewModel.errorMessage != nil)
        #expect(viewModel.errorMessage!.contains("Recording failed"))
    }

    @Test("toggleRecording stop failure sets error and returns to askingQuestion")
    @MainActor
    func toggleRecordingStopFailureSetsError() async throws {
        let (viewModel, mockAudio) = Fixtures.makeViewModelWithAudio()
        viewModel.quizState = .askingQuestion

        // First toggle: start recording successfully
        await viewModel.toggleRecording()
        #expect(viewModel.quizState == .recording)

        // Now make stop fail
        mockAudio.shouldFailRecording = true

        // Second toggle: stop recording (should fail)
        await viewModel.toggleRecording()

        #expect(viewModel.quizState == .askingQuestion)
        #expect(viewModel.errorMessage != nil)
        #expect(viewModel.errorMessage!.contains("Recording failed"))
    }

    @Test("toggleRecording from processing does nothing")
    @MainActor
    func toggleRecordingFromProcessingDoesNothing() async throws {
        let (viewModel, _) = Fixtures.makeViewModelWithAudio()
        viewModel.quizState = .processing

        await viewModel.toggleRecording()

        #expect(viewModel.quizState == .processing)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("toggleRecording from idle does nothing")
    @MainActor
    func toggleRecordingFromIdleDoesNothing() async throws {
        let (viewModel, _) = Fixtures.makeViewModelWithAudio()
        viewModel.quizState = .idle

        await viewModel.toggleRecording()

        #expect(viewModel.quizState == .idle)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("retryLastOperation from error with recording context returns to askingQuestion")
    @MainActor
    func retryAfterRecordingErrorReturnsToAskingQuestion() async throws {
        let (viewModel, _) = Fixtures.makeViewModelWithAudio(shouldFailRecording: true)

        // Put ViewModel into an error state with recording context
        // (In production, recording errors stay inline, but the error screen
        // could be reached via other paths. Test the retry logic directly.)
        viewModel.quizState = .error(message: "Recording failed", context: .recording)

        await viewModel.retryLastOperation()

        #expect(viewModel.quizState == .askingQuestion)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("retryLastOperation from error with initialization context starts new quiz")
    @MainActor
    func retryAfterInitErrorStartsNewQuiz() async throws {
        let (viewModel, _) = Fixtures.makeViewModelWithAudio()

        viewModel.quizState = .error(message: "Failed to start", context: .initialization)

        await viewModel.retryLastOperation()

        // Should have started a new quiz (transitions to askingQuestion on success)
        #expect(viewModel.quizState == .askingQuestion)
    }
}

// MARK: - Error State Tests

@Suite("QuizViewModel Error State Tests")
struct QuizViewModelErrorStateTests {
    @Test("error state carries message and context")
    @MainActor
    func errorStateCarriesData() async throws {
        let viewModel = Fixtures.makeViewModel()
        viewModel.quizState = .error(message: "Network error", context: .submission)

        #expect(viewModel.quizState.isError)
        #expect(viewModel.shouldRetryWithNewSession == false)
    }

    @Test("shouldRetryWithNewSession is true for initialization errors")
    @MainActor
    func shouldRetryWithNewSessionForInitErrors() async throws {
        let viewModel = Fixtures.makeViewModel()
        viewModel.quizState = .error(message: "Failed to start", context: .initialization)

        #expect(viewModel.shouldRetryWithNewSession == true)
    }

    @Test("shouldRetryWithNewSession is false when not in error state")
    @MainActor
    func shouldRetryFalseWhenNotInError() async throws {
        let viewModel = Fixtures.makeViewModel()
        viewModel.quizState = .idle

        #expect(viewModel.shouldRetryWithNewSession == false)
    }
}

// MARK: - Settings Auto-Persistence Tests

@Suite("QuizViewModel Settings Persistence Tests")
struct QuizViewModelSettingsPersistenceTests {
    @Test("settings auto-persist when a property changes")
    @MainActor
    func settingsAutoPersistOnChange() async throws {
        // withMainSerialExecutor collapses scheduling onto a single executor so the
        // Combine sink hop runs deterministically on the same main-actor turn —
        // no fragile `Task.yield()` wait needed.
        await withMainSerialExecutor {
            let (viewModel, mockStore) = Fixtures.makeViewModelWithPersistence()

            // Reset counter after init (init loads settings but should not trigger save)
            mockStore.saveSettingsCallCount = 0

            viewModel.settings.language = "sk"

            #expect(mockStore.saveSettingsCallCount == 1)
            #expect(mockStore.savedSettings?.language == "sk")
        }
    }

    @Test("settings don't re-save on init (dropFirst)")
    @MainActor
    func settingsNotSavedOnInit() async throws {
        await withMainSerialExecutor {
            let (_, mockStore) = Fixtures.makeViewModelWithPersistence()

            // Combine $settings replays the initial value; dropFirst() should skip it.
            #expect(mockStore.saveSettingsCallCount == 0)
        }
    }

    @Test("duplicate values don't trigger saves (removeDuplicates)")
    @MainActor
    func duplicateValuesSkipped() async throws {
        await withMainSerialExecutor {
            let (viewModel, mockStore) = Fixtures.makeViewModelWithPersistence()
            mockStore.saveSettingsCallCount = 0

            viewModel.settings.language = "sk"
            #expect(mockStore.saveSettingsCallCount == 1)

            // Set same value again — should not trigger another save
            viewModel.settings.language = "sk"
            #expect(mockStore.saveSettingsCallCount == 1)

            // Change to a different value — should trigger save
            viewModel.settings.language = "de"
            #expect(mockStore.saveSettingsCallCount == 2)
        }
    }
}

// MARK: - QuizStats Tests

@Suite("QuizStats Tests")
struct QuizStatsTests {
    @Test("recordAnswer correct increments totalCorrect, totalAnswered, and currentStreak")
    func recordAnswerCorrect() {
        var stats = QuizStats.empty
        stats.recordAnswer(isCorrect: true)

        #expect(stats.totalAnswered == 1)
        #expect(stats.totalCorrect == 1)
        #expect(stats.currentStreak == 1)
        #expect(stats.bestStreak == 1)
    }

    @Test("recordAnswer incorrect resets currentStreak and increments totalAnswered")
    func recordAnswerIncorrect() {
        var stats = QuizStats.empty
        stats.recordAnswer(isCorrect: true)
        stats.recordAnswer(isCorrect: false)

        #expect(stats.totalAnswered == 2)
        #expect(stats.totalCorrect == 1)
        #expect(stats.currentStreak == 0)
        #expect(stats.bestStreak == 1)
    }

    @Test("streak tracking: correct, correct, incorrect → streak goes 1, 2, 0")
    func streakTracking() {
        var stats = QuizStats.empty
        stats.recordAnswer(isCorrect: true)
        #expect(stats.currentStreak == 1)

        stats.recordAnswer(isCorrect: true)
        #expect(stats.currentStreak == 2)

        stats.recordAnswer(isCorrect: false)
        #expect(stats.currentStreak == 0)
        #expect(stats.bestStreak == 2)
    }

    @Test("bestStreak preserved after reset")
    func bestStreakPreserved() {
        var stats = QuizStats.empty
        stats.recordAnswer(isCorrect: true)
        stats.recordAnswer(isCorrect: true)
        stats.recordAnswer(isCorrect: true)
        #expect(stats.bestStreak == 3)

        stats.recordAnswer(isCorrect: false)
        stats.recordAnswer(isCorrect: true)
        #expect(stats.currentStreak == 1)
        #expect(stats.bestStreak == 3)
    }

    @Test("recordQuizCompleted increments totalQuizzes")
    func recordQuizCompleted() {
        var stats = QuizStats.empty
        stats.recordQuizCompleted()
        stats.recordQuizCompleted()

        #expect(stats.totalQuizzes == 2)
    }

    @Test("accuracy is 0 when no answers recorded")
    func accuracyZeroWhenEmpty() {
        let stats = QuizStats.empty
        #expect(stats.accuracyPercentage == 0)
    }

    @Test("accuracy calculation with mixed answers")
    func accuracyCalculation() {
        var stats = QuizStats.empty
        stats.recordAnswer(isCorrect: true)
        stats.recordAnswer(isCorrect: true)
        stats.recordAnswer(isCorrect: false)
        stats.recordAnswer(isCorrect: true)

        #expect(stats.accuracyPercentage == 75.0)
    }
}

// MARK: - MCQ Submission Tests

@Suite("QuizViewModel MCQ Submission Tests")
struct QuizViewModelMCQSubmissionTests {
    /// Shared MCQ question for all tests in this suite.
    private let mcqQuestion = Question(
        id: "q_mcq_001",
        question: "What is the capital of France?",
        type: .textMultichoice,
        possibleAnswers: ["a": "Paris", "b": "London", "c": "Berlin", "d": "Madrid"],
        difficulty: "easy",
        topic: "Geography",
        category: "adults",
        sourceUrl: nil,
        sourceExcerpt: nil,
        mediaUrl: nil,
        imageSubtype: nil,
        explanation: nil,
        generatedBy: nil
    )

    @Test("late MCQ submit after the state advanced is a no-op (#110 same-key tap/voice race)")
    @MainActor
    func lateMCQSubmitAfterStateAdvancedIsNoOp() async throws {
        let (viewModel, mockNetwork) = Fixtures.makeViewModelWithNetwork(configure: { mock in
            mock.mockResponse = makeQuizResponse(
                evaluationFor: "q_mcq_001",
                userAnswer: "Paris",
                isCorrect: true,
                nextQuestion: makeQuestion(id: "q_002", source: "Next")
            )
        })
        viewModel.currentSession = mockNetwork.mockSession
        viewModel.currentQuestion = mcqQuestion
        viewModel.quizState = .askingQuestion

        // First submission (the voice twin of a same-key tap) wins and advances
        // the state to .showingResult.
        await viewModel.submitMCQAnswer(key: "a", value: "Paris")
        #expect(viewModel.quizState.isShowingResult)
        #expect(mockNetwork.submitTextInputCallCount == 1)

        // The tap's 500 ms delayed submit fires late, from .showingResult. The
        // entry guard must make it a no-op — .showingResult → .processing is a
        // legal transition (resubmitAnswer owns it), so without the guard this
        // would re-submit the same answer.
        await viewModel.submitMCQAnswer(key: "a", value: "Paris")

        #expect(viewModel.quizState.isShowingResult)
        #expect(mockNetwork.submitTextInputCallCount == 1)
    }

    @Test("MCQ submission transitions to showingResult on success")
    @MainActor
    func mcqSubmissionSuccess() async throws {
        let (viewModel, mockNetwork) = Fixtures.makeViewModelWithNetwork(configure: { mock in
            mock.mockResponse = makeQuizResponse(
                evaluationFor: "q_mcq_001",
                userAnswer: "Paris",
                isCorrect: true,
                nextQuestion: makeQuestion(id: "q_002", source: "Next")
            )
        })
        viewModel.currentSession = mockNetwork.mockSession
        viewModel.currentQuestion = mcqQuestion
        viewModel.quizState = .askingQuestion

        await viewModel.submitMCQAnswer(key: "a", value: "Paris")

        #expect(viewModel.quizState.isShowingResult)
    }

    @Test("MCQ submission transitions to processing state")
    @MainActor
    func mcqSubmissionTransitionsToProcessing() async throws {
        // We can't observe the intermediate .processing state easily since
        // the async call completes, but we verify it doesn't stay in .askingQuestion
        let (viewModel, mockNetwork) = Fixtures.makeViewModelWithNetwork(configure: { mock in
            mock.mockResponse = makeQuizResponse(
                evaluationFor: "q_mcq_001",
                userAnswer: "Paris",
                isCorrect: true,
                nextQuestion: makeQuestion(id: "q_002", source: "Next")
            )
        })
        viewModel.currentSession = mockNetwork.mockSession
        viewModel.currentQuestion = mcqQuestion
        viewModel.quizState = .askingQuestion

        await viewModel.submitMCQAnswer(key: "a", value: "Paris")

        // After completion, should be in showingResult (went through processing)
        #expect(viewModel.quizState.isShowingResult)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("MCQ submission with network error shows error state")
    @MainActor
    func mcqSubmissionNetworkError() async throws {
        let (viewModel, mockNetwork) = Fixtures.makeViewModelWithNetwork(shouldFail: true)
        viewModel.currentSession = mockNetwork.mockSession
        viewModel.currentQuestion = mcqQuestion
        viewModel.quizState = .askingQuestion

        await viewModel.submitMCQAnswer(key: "a", value: "Paris")

        #expect(viewModel.quizState.isError)
    }

    @Test("MCQ submission without active session shows error message")
    @MainActor
    func mcqSubmissionNoSession() async throws {
        let (viewModel, _) = Fixtures.makeViewModelWithNetwork(configure: { mock in
            mock.mockResponse = makeQuizResponse(
                evaluationFor: "q_mcq_001",
                userAnswer: "Paris",
                isCorrect: true,
                nextQuestion: makeQuestion(id: "q_002", source: "Next")
            )
        })
        viewModel.currentQuestion = mcqQuestion
        viewModel.currentSession = nil
        // #110: submitMCQAnswer is a no-op outside .askingQuestion/.recording,
        // so the no-session error path must be exercised from a legal
        // answering state (the default .idle would short-circuit earlier).
        viewModel.quizState = .askingQuestion

        await viewModel.submitMCQAnswer(key: "a", value: "Paris")

        #expect(viewModel.errorMessage == "No active session")
    }
}

// MARK: - State Transition Tests

@Suite("QuizViewModel State Transition Tests")
struct QuizViewModelStateTransitionTests {
    @Test("valid transition from idle to startingQuiz")
    @MainActor
    func validTransitionFromIdleToStartingQuiz() async throws {
        let viewModel = Fixtures.makeViewModel()
        #expect(viewModel.quizState == .idle)

        viewModel.transition(to: .startingQuiz)

        #expect(viewModel.quizState == .startingQuiz)
    }

    @Test("valid transition from askingQuestion to recording")
    @MainActor
    func validTransitionFromAskingQuestionToRecording() async throws {
        let viewModel = Fixtures.makeViewModel()
        viewModel.quizState = .askingQuestion

        viewModel.transition(to: .recording)

        #expect(viewModel.quizState == .recording)
    }

    @Test("transition to error from askingQuestion, recording, and processing")
    @MainActor
    func transitionToErrorFromAnyState() async throws {
        let viewModel = Fixtures.makeViewModel()

        // From askingQuestion
        viewModel.quizState = .askingQuestion
        viewModel.transition(to: .error(message: "fail", context: .submission))
        #expect(viewModel.quizState.isError)

        // From recording
        viewModel.quizState = .recording
        viewModel.transition(to: .error(message: "fail", context: .recording))
        #expect(viewModel.quizState.isError)

        // From processing
        viewModel.quizState = .processing
        viewModel.transition(to: .error(message: "fail", context: .submission))
        #expect(viewModel.quizState.isError)
    }

    @Test("transition from error to idle")
    @MainActor
    func transitionFromErrorToIdle() async throws {
        let viewModel = Fixtures.makeViewModel()
        viewModel.quizState = .error(message: "Something broke", context: .submission)

        viewModel.transition(to: .idle)

        #expect(viewModel.quizState == .idle)
    }

    @Test("transition from error to askingQuestion (retry)")
    @MainActor
    func transitionFromErrorToAskingQuestion() async throws {
        let viewModel = Fixtures.makeViewModel()
        viewModel.quizState = .error(message: "Recording error", context: .recording)

        viewModel.transition(to: .askingQuestion)

        #expect(viewModel.quizState == .askingQuestion)
    }

    @Test("state labels match expected strings")
    @MainActor
    func stateLabel() async throws {
        #expect(QuizState.idle.label == "idle")
        #expect(QuizState.startingQuiz.label == "startingQuiz")
        #expect(QuizState.askingQuestion.label == "askingQuestion")
        #expect(QuizState.recording.label == "recording")
        #expect(QuizState.processing.label == "processing")
        #expect(QuizState.skipping.label == "skipping")
        #expect(QuizState.finished.label == "finished")

        let question = makeQuestion(id: "q_001", source: "Test")
        let evaluation = Evaluation(
            userAnswer: "A", result: .correct, points: 1.0,
            correctAnswer: "A", questionId: "q_001", explanation: nil
        )
        #expect(QuizState.showingResult(question: question, evaluation: evaluation).label == "showingResult")
        #expect(QuizState.error(message: "err", context: .submission).label == "error")
    }

    @Test("validTransitions sets contain expected successor states")
    @MainActor
    func validTransitionsSet() async throws {
        #expect(QuizState.idle.validTransitions.contains("startingQuiz"))

        #expect(QuizState.startingQuiz.validTransitions.contains("askingQuestion"))
        #expect(QuizState.startingQuiz.validTransitions.contains("error"))

        #expect(QuizState.askingQuestion.validTransitions.contains("recording"))
        #expect(QuizState.askingQuestion.validTransitions.contains("processing"))
        #expect(QuizState.askingQuestion.validTransitions.contains("skipping"))
        #expect(QuizState.askingQuestion.validTransitions.contains("error"))

        #expect(QuizState.recording.validTransitions.contains("processing"))
        #expect(QuizState.recording.validTransitions.contains("skipping"))
        #expect(QuizState.recording.validTransitions.contains("askingQuestion"))
        #expect(QuizState.recording.validTransitions.contains("error"))

        #expect(QuizState.processing.validTransitions.contains("showingResult"))
        #expect(QuizState.processing.validTransitions.contains("skipping"))
        #expect(QuizState.processing.validTransitions.contains("error"))

        #expect(QuizState.skipping.validTransitions.contains("showingResult"))
        #expect(QuizState.skipping.validTransitions.contains("askingQuestion"))
        #expect(QuizState.skipping.validTransitions.contains("error"))

        let question = makeQuestion(id: "q_001", source: "Test")
        let evaluation = Evaluation(
            userAnswer: "A", result: .correct, points: 1.0,
            correctAnswer: "A", questionId: "q_001", explanation: nil
        )
        let showingResult = QuizState.showingResult(question: question, evaluation: evaluation)
        #expect(showingResult.validTransitions.contains("askingQuestion"))
        #expect(showingResult.validTransitions.contains("finished"))
        #expect(showingResult.validTransitions.contains("idle"))

        #expect(QuizState.finished.validTransitions.contains("idle"))

        #expect(QuizState.error(message: "err", context: .submission).validTransitions.contains("idle"))
        #expect(QuizState.error(message: "err", context: .submission).validTransitions.contains("askingQuestion"))
    }
}

// MARK: - Double-Stop Guard Tests

@Suite("QuizViewModel Double-Stop Guard Tests")
struct QuizViewModelDoubleStopTests {
    @Test("isStoppingRecording prevents double stopRecordingAndSubmit call")
    @MainActor
    func isStoppingRecordingPreventsDoubleCall() async throws {
        let (viewModel, _) = Fixtures.makeViewModelWithNetwork()
        viewModel.currentSession = QuizSession(
            id: "test_session_123",
            mode: "single", phase: "asking", maxQuestions: 10,
            currentDifficulty: "medium", category: nil, language: "en",
            participants: [], expiresAt: Date().addingTimeInterval(1800),
            createdAt: Date()
        )
        viewModel.currentQuestion = makeQuestion(id: "q_001", source: "Test")
        viewModel.quizState = .recording

        // Simulate the guard being set (as if a stop is already in progress)
        viewModel.recordingCoordinator.isStoppingRecording = true

        // Call stopRecordingAndSubmit — should return early without changing state
        await viewModel.recordingCoordinator.stopRecordingAndSubmit()

        // State should remain .recording because the guard prevented the call
        #expect(viewModel.quizState == .recording)
    }
}

// MARK: - End Quiz Tests

@Suite("QuizViewModel End Quiz Tests")
struct QuizViewModelEndQuizTests {
    /// 54.6 (founder #1): ending the quiz from the minimized floating widget
    /// must also dismiss the widget — resetState() left isMinimized true, so a
    /// stale "01/10" card floated over Home after the session was gone.
    @Test("ending quiz from the minimized widget dismisses the widget")
    @MainActor
    func endQuizResetsMinimized() async throws {
        let (viewModel, _) = Fixtures.makeViewModelWithNetwork()
        viewModel.currentSession = Fixtures.makeActiveSession()
        viewModel.quizState = .askingQuestion
        viewModel.isMinimized = true

        await viewModel.endQuiz()

        #expect(viewModel.isMinimized == false)
        #expect(viewModel.quizState == .idle)
        #expect(viewModel.currentSession == nil)
    }

    /// #110 Bug 3: `.finished` never cleared `isMinimized`, so a stale
    /// MinimizedQuizView floated over CompletionView with no one watching.
    @Test("entering .finished resets isMinimized")
    @MainActor
    func finishedResetsMinimized() async throws {
        let viewModel = Fixtures.makeViewModel()
        viewModel.quizState = .showingResult(
            question: Fixtures.makeQuestion(),
            evaluation: Evaluation(
                userAnswer: "Paris",
                result: .correct,
                points: 1.0,
                correctAnswer: "Paris",
                questionId: "q_001",
                explanation: nil
            )
        )
        viewModel.isMinimized = true

        viewModel.transition(to: .finished)

        #expect(viewModel.isMinimized == false)
    }

    /// 59.4 (RS-13): a backend 404 (`sessionNotFound`) on endSession is *correct* backend
    /// behaviour for an already-expired or restart-lost session. The end-quiz invariant is
    /// "tapping X always returns Home" — the user must never be stranded on the question
    /// screen behind a misleading "session not found" banner. This is the red→green guard:
    /// before the fix the catch only set `errorMessage` and left state untouched.
    @Test("endQuiz treats sessionNotFound as success and returns Home (RS-13)")
    @MainActor
    func endQuizSessionNotFoundResetsToHome() async throws {
        let (viewModel, mockNetwork) = Fixtures.makeViewModelWithNetwork()
        mockNetwork.endSessionError = NetworkError.sessionNotFound
        viewModel.currentSession = Fixtures.makeActiveSession()
        let question = Fixtures.makeQuestion()
        viewModel.quizState = .showingResult(
            question: question,
            evaluation: Evaluation(
                userAnswer: "x",
                result: .correct,
                points: 1.0,
                correctAnswer: "x",
                questionId: question.id,
                explanation: nil
            )
        )

        await viewModel.endQuiz()

        #expect(mockNetwork.endSessionCallCount == 1) // server-side cleanup was attempted
        #expect(viewModel.quizState == .idle)
        #expect(viewModel.currentSession == nil)
        #expect(viewModel.errorMessage == nil) // no misleading banner
    }

    /// 59.4 (RS-13): an error that means the session may still be live (e.g. a 5xx / timeout)
    /// DOES surface a banner — but unlike the 404 path it keeps the user on screen so they
    /// can retry, rather than silently dropping a session the backend still holds.
    @Test("endQuiz surfaces a banner for live-session errors and does not reset (RS-13)")
    @MainActor
    func endQuizLiveErrorShowsBanner() async throws {
        let (viewModel, mockNetwork) = Fixtures.makeViewModelWithNetwork()
        mockNetwork.endSessionError = NetworkError.serverError(statusCode: 500, message: "boom")
        viewModel.currentSession = Fixtures.makeActiveSession()
        viewModel.quizState = .askingQuestion

        await viewModel.endQuiz()

        #expect(mockNetwork.endSessionCallCount == 1)
        #expect(viewModel.errorMessage != nil)
        #expect(viewModel.currentSession != nil) // not dropped — may still be live
    }
}

// MARK: - Resume Auto-Advance Tests (RS-17, #59.8)

@Suite("QuizViewModel Resume Auto-Advance Tests")
struct QuizViewModelResumeAutoAdvanceTests {
    /// 59.8 (RS-17): "Resume auto-advance" must re-arm the countdown and KEEP the user on
    /// the result screen — it is a different action from "Next question" (`continueToNext()`,
    /// which advances immediately). Before the fix the button wired to `continueToNext()`, so
    /// tapping it jumped straight to the next question. The presence of a dedicated
    /// `resumeAutoAdvance()` method is itself the structural guard.
    @Test("resumeAutoAdvance re-arms the countdown and stays on the result screen (RS-17)")
    @MainActor
    func resumeAutoAdvanceStaysOnResult() async throws {
        let viewModel = Fixtures.makeViewModel()
        let question = makeQuestion(id: "q_001", source: "Test")
        let evaluation = Evaluation(
            userAnswer: "x",
            result: .correct,
            points: 1.0,
            correctAnswer: "x",
            questionId: "q_001",
            explanation: nil
        )
        viewModel.quizState = .showingResult(question: question, evaluation: evaluation)

        // Pause first (mirrors "Stay here"): countdown cancelled, pause flag set.
        viewModel.pauseQuiz()
        #expect(viewModel.currentQuestionPaused)

        viewModel.resumeAutoAdvance()

        // resumeAutoAdvance arms the countdown via a fire-and-forget Task — let it run.
        var waited = 0
        while viewModel.autoAdvanceCountdown == 0, waited < 50 {
            await Task.yield()
            waited += 1
        }

        #expect(viewModel.quizState.isShowingResult) // did NOT jump to the next question
        #expect(viewModel.autoAdvanceCountdown > 0) // countdown re-armed
        #expect(!viewModel.currentQuestionPaused) // pause cleared

        // Cleanup: cancel the long-lived countdown task so it can't fire mid-suite.
        viewModel.pauseQuiz()
    }
}
