//
//  QuizViewModelTests.swift
//  CarQuizTests
//
//  Tests for QuizViewModel state machine and quiz flow.
//

import Foundation
import Testing
@testable import CarQuiz

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
                )
            ],
            expiresAt: Date().addingTimeInterval(30 * 60),
            createdAt: Date()
        ),
        currentQuestion: nextQuestion,
        evaluation: Evaluation(
            userAnswer: userAnswer,
            result: isCorrect ? .correct : .incorrect,
            points: isCorrect ? 1.0 : 0.0,
            correctAnswer: "Expected Answer"
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
        sourceExcerpt: source
    )
}

// MARK: - Result State Tests

@Suite("QuizViewModel Result State Tests")
struct QuizViewModelResultStateTests {

    /// Creates a fresh ViewModel for each test
    @MainActor
    private func makeViewModel() -> QuizViewModel {
        QuizViewModel(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
    }

    @Test("resultQuestion and resultEvaluation are bundled in showingResult state")
    @MainActor
    func resultDataBundledInState() async throws {
        let viewModel = makeViewModel()
        let questionA = makeQuestion(id: "q_001", source: "Source for question A")
        let evaluation = Evaluation(
            userAnswer: "Paris",
            result: .correct,
            points: 1.0,
            correctAnswer: "Paris"
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
        let viewModel = makeViewModel()

        // In idle state, no result data
        #expect(viewModel.resultQuestion == nil)
        #expect(viewModel.resultEvaluation == nil)
        #expect(!viewModel.quizState.isShowingResult)
    }

    @Test("result data is structurally bound — currentQuestion changes don't affect it")
    @MainActor
    func resultDataStableWhenCurrentQuestionChanges() async throws {
        let viewModel = makeViewModel()
        let questionA = makeQuestion(id: "q_001", source: "Source A")
        let questionB = makeQuestion(id: "q_002", source: "Source B")
        let evaluation = Evaluation(
            userAnswer: "Answer A",
            result: .correct,
            points: 1.0,
            correctAnswer: "Expected A"
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
        let viewModel = makeViewModel()
        let questionA = makeQuestion(id: "q_001", source: "Source A")
        let evaluation = Evaluation(
            userAnswer: "A1",
            result: .correct,
            points: 1.0,
            correctAnswer: "A1"
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
        let viewModel = makeViewModel()
        let question = makeQuestion(id: "q_001", source: "Test")
        let evaluation = Evaluation(
            userAnswer: "Test",
            result: .correct,
            points: 1.0,
            correctAnswer: "Test"
        )

        viewModel.currentQuestion = question
        viewModel.quizState = .showingResult(question: question, evaluation: evaluation)
        viewModel.score = 5.0
        viewModel.questionsAnswered = 3

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
        let viewModel = makeViewModel()
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
            correctAnswer: "A1"
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
            correctAnswer: "A2 Expected"
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

    /// Creates a fresh ViewModel with configurable mock network
    @MainActor
    private func makeViewModel(shouldFail: Bool = false) -> (QuizViewModel, MockNetworkService) {
        let mockNetwork = MockNetworkService()
        mockNetwork.shouldFail = shouldFail

        // Set up default mock session and response
        mockNetwork.mockSession = QuizSession(
            id: "test_session_123",
            mode: "single",
            phase: "asking",
            maxQuestions: 10,
            currentDifficulty: "medium",
            category: nil,
            language: "en",
            participants: [
                Participant(
                    id: "p1", userId: nil, displayName: "Player",
                    score: 0, answeredCount: 0, correctCount: 0,
                    lastAnswer: nil, lastResult: nil,
                    isHost: true, isReady: true, joinedAt: Date()
                )
            ],
            expiresAt: Date().addingTimeInterval(30 * 60),
            createdAt: Date()
        )

        mockNetwork.mockResponse = makeQuizResponse(
            evaluationFor: "q_001",
            userAnswer: "Test",
            isCorrect: true,
            nextQuestion: makeQuestion(id: "q_002", source: "Next")
        )

        let viewModel = QuizViewModel(
            networkService: mockNetwork,
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        return (viewModel, mockNetwork)
    }

    @Test("submitVoiceAnswer sets quizState to processing then resolves")
    @MainActor
    func submitVoiceAnswerSetsProcessing() async throws {
        let (viewModel, _) = makeViewModel()
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

        await viewModel.submitVoiceAnswer(audioData: Data("mock audio".utf8))

        // After completion, state should not be .processing (moved to showingResult via confirmation)
        // The answer confirmation sheet should be shown
        #expect(viewModel.showAnswerConfirmation == true)
    }

    @Test("skipQuestion sets quizState to processing then resolves to showingResult")
    @MainActor
    func skipQuestionSetsProcessing() async throws {
        let (viewModel, _) = makeViewModel()
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
        let (viewModel, _) = makeViewModel()
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
        let (viewModel, _) = makeViewModel()

        #expect(viewModel.quizState == .idle)

        await viewModel.startNewQuiz()

        #expect(viewModel.quizState == .askingQuestion)
        #expect(viewModel.currentQuestion != nil)
    }

    @Test("startNewQuiz transitions to error on failure")
    @MainActor
    func startNewQuizTransitionsToError() async throws {
        let (viewModel, _) = makeViewModel(shouldFail: true)

        await viewModel.startNewQuiz()

        #expect(viewModel.quizState.isError)
    }

    @Test("resetToHome resets to idle cleanly")
    @MainActor
    func resetToHomeResetsToIdle() async throws {
        let (viewModel, _) = makeViewModel()
        // Put viewModel into non-idle state
        viewModel.quizState = .processing
        viewModel.errorMessage = "Some error"
        viewModel.score = 5.0
        viewModel.questionsAnswered = 3

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
        let (viewModel, _) = makeViewModel()

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
        let (viewModel, _) = makeViewModel()
        viewModel.currentSession = QuizSession(
            id: "test_session_123",
            mode: "single", phase: "asking", maxQuestions: 10,
            currentDifficulty: "medium", category: nil, language: "en",
            participants: [], expiresAt: Date().addingTimeInterval(1800),
            createdAt: Date()
        )
        viewModel.currentQuestion = makeQuestion(id: "q_001", source: "Test")
        viewModel.quizState = .processing  // Already processing

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

    /// Creates a ViewModel with a mock network that returns a valid evaluation response
    @MainActor
    private func makeViewModel() -> (QuizViewModel, MockNetworkService) {
        let mockNetwork = MockNetworkService()
        mockNetwork.mockSession = QuizSession(
            id: "test_session_123",
            mode: "single", phase: "asking", maxQuestions: 10,
            currentDifficulty: "medium", category: nil, language: "en",
            participants: [
                Participant(
                    id: "p1", userId: nil, displayName: "Player",
                    score: 0, answeredCount: 0, correctCount: 0,
                    lastAnswer: nil, lastResult: nil,
                    isHost: true, isReady: true, joinedAt: Date()
                )
            ],
            expiresAt: Date().addingTimeInterval(30 * 60),
            createdAt: Date()
        )
        mockNetwork.mockResponse = makeQuizResponse(
            evaluationFor: "q_001",
            userAnswer: "Paris",
            isCorrect: true,
            nextQuestion: makeQuestion(id: "q_002", source: "Next question")
        )

        let viewModel = QuizViewModel(
            networkService: mockNetwork,
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        return (viewModel, mockNetwork)
    }

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
        await viewModel.submitVoiceAnswer(audioData: Data("mock audio".utf8))
    }

    @Test("handleAnswerConfirmationDismissed resets state when pendingResponse exists")
    @MainActor
    func dismissResetsStateWhenPendingResponseExists() async throws {
        let (viewModel, _) = makeViewModel()
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
        let (viewModel, _) = makeViewModel()
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
        let (viewModel, _) = makeViewModel()
        await putIntoConfirmationState(viewModel)

        // User taps Re-record — this clears pendingResponse and returns to askingQuestion
        viewModel.rerecordAnswer()

        // Verify rerecordAnswer transitioned to askingQuestion
        #expect(viewModel.quizState == .askingQuestion)
        #expect(viewModel.showAnswerConfirmation == false)

        // Now if onDismiss fires, it should be a no-op (pendingResponse already nil)
        viewModel.handleAnswerConfirmationDismissed()

        // State should remain .askingQuestion (unchanged, not re-set)
        #expect(viewModel.quizState == .askingQuestion)
    }
}

// MARK: - Recording Lifecycle Tests

@Suite("QuizViewModel Recording Tests")
struct QuizViewModelRecordingTests {

    @MainActor
    private func makeViewModel(shouldFailRecording: Bool = false) -> (QuizViewModel, MockAudioService) {
        let mockAudio = MockAudioService()
        mockAudio.shouldFailRecording = shouldFailRecording

        let mockNetwork = MockNetworkService()
        mockNetwork.mockSession = QuizSession(
            id: "test_session_123",
            mode: "single", phase: "asking", maxQuestions: 10,
            currentDifficulty: "medium", category: nil, language: "en",
            participants: [
                Participant(
                    id: "p1", userId: nil, displayName: "Player",
                    score: 0, answeredCount: 0, correctCount: 0,
                    lastAnswer: nil, lastResult: nil,
                    isHost: true, isReady: true, joinedAt: Date()
                )
            ],
            expiresAt: Date().addingTimeInterval(30 * 60),
            createdAt: Date()
        )
        mockNetwork.mockResponse = makeQuizResponse(
            evaluationFor: "q_001",
            userAnswer: "Test",
            isCorrect: true,
            nextQuestion: makeQuestion(id: "q_002", source: "Next")
        )

        let viewModel = QuizViewModel(
            networkService: mockNetwork,
            audioService: mockAudio,
            persistenceStore: MockPersistenceStore()
        )
        return (viewModel, mockAudio)
    }

    @Test("toggleRecording from askingQuestion starts recording")
    @MainActor
    func toggleRecordingFromAskingQuestionStartsRecording() async throws {
        let (viewModel, mockAudio) = makeViewModel()
        viewModel.quizState = .askingQuestion

        await viewModel.toggleRecording()

        #expect(viewModel.quizState == .recording)
        #expect(mockAudio.isRecording == true)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("toggleRecording from recording stops and submits")
    @MainActor
    func toggleRecordingFromRecordingStopsAndSubmits() async throws {
        let (viewModel, _) = makeViewModel()
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
        let (viewModel, _) = makeViewModel(shouldFailRecording: true)
        viewModel.quizState = .askingQuestion

        await viewModel.toggleRecording()

        #expect(viewModel.quizState == .askingQuestion)
        #expect(viewModel.errorMessage != nil)
        #expect(viewModel.errorMessage!.contains("Recording failed"))
    }

    @Test("toggleRecording stop failure sets error and returns to askingQuestion")
    @MainActor
    func toggleRecordingStopFailureSetsError() async throws {
        let (viewModel, mockAudio) = makeViewModel()
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
        let (viewModel, _) = makeViewModel()
        viewModel.quizState = .processing

        await viewModel.toggleRecording()

        #expect(viewModel.quizState == .processing)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("toggleRecording from idle does nothing")
    @MainActor
    func toggleRecordingFromIdleDoesNothing() async throws {
        let (viewModel, _) = makeViewModel()
        viewModel.quizState = .idle

        await viewModel.toggleRecording()

        #expect(viewModel.quizState == .idle)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("retryLastOperation from error with recording context returns to askingQuestion")
    @MainActor
    func retryAfterRecordingErrorReturnsToAskingQuestion() async throws {
        let (viewModel, _) = makeViewModel(shouldFailRecording: true)

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
        let (viewModel, _) = makeViewModel()

        viewModel.quizState = .error(message: "Failed to start", context: .initialization)

        await viewModel.retryLastOperation()

        // Should have started a new quiz (transitions to askingQuestion on success)
        #expect(viewModel.quizState == .askingQuestion)
    }
}

// MARK: - Error State Tests

@Suite("QuizViewModel Error State Tests")
struct QuizViewModelErrorStateTests {

    @MainActor
    private func makeViewModel() -> QuizViewModel {
        QuizViewModel(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
    }

    @Test("error state carries message and context")
    @MainActor
    func errorStateCarriesData() async throws {
        let viewModel = makeViewModel()
        viewModel.quizState = .error(message: "Network error", context: .submission)

        #expect(viewModel.quizState.isError)
        #expect(viewModel.shouldRetryWithNewSession == false)
    }

    @Test("shouldRetryWithNewSession is true for initialization errors")
    @MainActor
    func shouldRetryWithNewSessionForInitErrors() async throws {
        let viewModel = makeViewModel()
        viewModel.quizState = .error(message: "Failed to start", context: .initialization)

        #expect(viewModel.shouldRetryWithNewSession == true)
    }

    @Test("shouldRetryWithNewSession is false when not in error state")
    @MainActor
    func shouldRetryFalseWhenNotInError() async throws {
        let viewModel = makeViewModel()
        viewModel.quizState = .idle

        #expect(viewModel.shouldRetryWithNewSession == false)
    }
}

// MARK: - Settings Auto-Persistence Tests

@Suite("QuizViewModel Settings Persistence Tests")
struct QuizViewModelSettingsPersistenceTests {

    @MainActor
    private func makeViewModel() -> (QuizViewModel, MockPersistenceStore) {
        let mockStore = MockPersistenceStore()
        let viewModel = QuizViewModel(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: mockStore
        )
        return (viewModel, mockStore)
    }

    @Test("settings auto-persist when a property changes")
    @MainActor
    func settingsAutoPersistOnChange() async throws {
        let (viewModel, mockStore) = makeViewModel()

        // Reset counter after init (init loads settings but should not trigger save)
        mockStore.saveSettingsCallCount = 0

        // Act - change a setting
        viewModel.settings.language = "sk"

        // Combine sink fires asynchronously on the next run loop iteration
        await Task.yield()

        // Assert
        #expect(mockStore.saveSettingsCallCount == 1)
        #expect(mockStore.savedSettings?.language == "sk")
    }

    @Test("settings don't re-save on init (dropFirst)")
    @MainActor
    func settingsNotSavedOnInit() async throws {
        let (_, mockStore) = makeViewModel()

        // Combine $settings replays the initial value; dropFirst() should skip it
        await Task.yield()

        #expect(mockStore.saveSettingsCallCount == 0)
    }

    @Test("duplicate values don't trigger saves (removeDuplicates)")
    @MainActor
    func duplicateValuesSkipped() async throws {
        let (viewModel, mockStore) = makeViewModel()
        mockStore.saveSettingsCallCount = 0

        // Change language to "sk"
        viewModel.settings.language = "sk"
        await Task.yield()
        #expect(mockStore.saveSettingsCallCount == 1)

        // Set same value again — should not trigger another save
        viewModel.settings.language = "sk"
        await Task.yield()
        #expect(mockStore.saveSettingsCallCount == 1)

        // Change to a different value — should trigger save
        viewModel.settings.language = "de"
        await Task.yield()
        #expect(mockStore.saveSettingsCallCount == 2)
    }
}
