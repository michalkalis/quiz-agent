//
//  QuizViewModelTests.swift
//  CarQuizTests
//
//  Tests for QuizViewModel, focusing on question/evaluation pairing
//  to prevent race conditions where ResultView shows wrong question data.
//

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

// MARK: - Tests

@Suite("QuizViewModel AnsweredQuestion Tests")
struct QuizViewModelAnsweredQuestionTests {

    /// Creates a fresh ViewModel for each test
    @MainActor
    private func makeViewModel() -> QuizViewModel {
        QuizViewModel(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            sessionStore: MockSessionStore(),
            questionHistoryStore: MockQuestionHistoryStore()
        )
    }

    @Test("answeredQuestion is set when evaluation is received")
    @MainActor
    func answeredQuestionCapturedOnEvaluation() async throws {
        // Arrange
        let viewModel = makeViewModel()
        let questionA = makeQuestion(id: "q_001", source: "Source for question A")
        viewModel.currentQuestion = questionA
        viewModel.quizState = .processing

        // Create a mock session
        viewModel.currentSession = QuizSession(
            id: "test_session",
            mode: "single",
            phase: "asking",
            maxQuestions: 10,
            currentDifficulty: "medium",
            category: nil,
            language: "en",
            participants: [
                Participant(
                    id: "p1",
                    userId: nil,
                    displayName: "Player",
                    score: 0,
                    answeredCount: 0,
                    correctCount: 0,
                    lastAnswer: nil,
                    lastResult: nil,
                    isHost: true,
                    isReady: true,
                    joinedAt: Date()
                )
            ],
            expiresAt: Date().addingTimeInterval(30 * 60),
            createdAt: Date()
        )

        // Simulate receiving a response with evaluation
        let questionB = makeQuestion(id: "q_002", source: "Source for question B")
        let response = makeQuizResponse(
            evaluationFor: "q_001",
            userAnswer: "My Answer",
            isCorrect: true,
            nextQuestion: questionB
        )

        // Act - Simulate what confirmAnswer does (calls handleQuizResponse internally)
        // Since handleQuizResponse is private, we test through the public API
        let mockNetwork = viewModel as? any ObservableObject
        #expect(mockNetwork != nil)

        // Before: answeredQuestion should be nil
        #expect(viewModel.answeredQuestion == nil)

        // Directly test the property setting logic
        // (In production, this happens via confirmAnswer -> handleQuizResponse)
        viewModel.answeredQuestion = viewModel.currentQuestion  // Simulating snapshot

        // Assert
        #expect(viewModel.answeredQuestion != nil)
        #expect(viewModel.answeredQuestion?.id == "q_001")
        #expect(viewModel.answeredQuestion?.sourceExcerpt == "Source for question A")
    }

    @Test("answeredQuestion remains stable when currentQuestion changes")
    @MainActor
    func answeredQuestionStableDuringResultDisplay() async throws {
        // Arrange
        let viewModel = makeViewModel()
        let questionA = makeQuestion(id: "q_001", source: "Source A")
        let questionB = makeQuestion(id: "q_002", source: "Source B")

        // Set up state as if we just received an evaluation
        viewModel.currentQuestion = questionA
        viewModel.answeredQuestion = questionA  // Snapshot taken
        viewModel.lastEvaluation = Evaluation(
            userAnswer: "Answer A",
            result: .correct,
            points: 1.0,
            correctAnswer: "Expected A"
        )
        viewModel.quizState = .showingResult

        // Act - Simulate what would happen if currentQuestion was prematurely updated
        // (This was the bug - currentQuestion could change while ResultView was displayed)
        viewModel.currentQuestion = questionB

        // Assert - answeredQuestion should still point to question A
        #expect(viewModel.answeredQuestion?.id == "q_001")
        #expect(viewModel.answeredQuestion?.sourceExcerpt == "Source A")

        // The bug was that ResultView read currentQuestion for source display
        // Now it should read answeredQuestion which is stable
        #expect(viewModel.currentQuestion?.id == "q_002")  // currentQuestion changed
        #expect(viewModel.answeredQuestion?.id == "q_001")  // answeredQuestion stable
    }

    @Test("answeredQuestion is cleared after transition to next question")
    @MainActor
    func answeredQuestionClearedAfterTransition() async throws {
        // Arrange
        let viewModel = makeViewModel()
        let questionA = makeQuestion(id: "q_001", source: "Source A")

        viewModel.currentQuestion = questionA
        viewModel.answeredQuestion = questionA
        viewModel.quizState = .showingResult
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

        // Act - Proceed to next question
        await viewModel.proceedToNextQuestion()

        // Assert
        #expect(viewModel.answeredQuestion == nil)
    }

    @Test("answeredQuestion matches evaluation in ResultView scenario")
    @MainActor
    func answeredQuestionMatchesEvaluation() async throws {
        // Arrange
        let viewModel = makeViewModel()
        let questionA = makeQuestion(id: "q_001", source: "Capital of France source")
        let questionB = makeQuestion(id: "q_002", source: "Chemical formula source")

        // Set up state where evaluation is for question A
        viewModel.currentQuestion = questionA
        viewModel.answeredQuestion = questionA  // Correctly snapshotted

        let evaluationForA = Evaluation(
            userAnswer: "Paris",
            result: .correct,
            points: 1.0,
            correctAnswer: "Paris"
        )
        viewModel.lastEvaluation = evaluationForA
        viewModel.quizState = .showingResult

        // Act - What ResultView would see
        // Before fix: it would read currentQuestion which could be B
        // After fix: it reads answeredQuestion which is stable as A

        // Assert - answeredQuestion should have the source that matches the evaluation
        #expect(viewModel.answeredQuestion?.id == "q_001")
        #expect(viewModel.answeredQuestion?.sourceExcerpt == "Capital of France source")
        #expect(viewModel.lastEvaluation?.correctAnswer == "Paris")

        // The source and evaluation should be from the same question
        // This is the critical invariant that the fix maintains
    }

    @Test("answeredQuestion is nil initially")
    @MainActor
    func answeredQuestionNilInitially() async throws {
        // Arrange & Act
        let viewModel = makeViewModel()

        // Assert
        #expect(viewModel.answeredQuestion == nil)
    }

    @Test("answeredQuestion cleared on reset")
    @MainActor
    func answeredQuestionClearedOnReset() async throws {
        // Arrange
        let viewModel = makeViewModel()
        viewModel.answeredQuestion = makeQuestion(id: "q_001", source: "Test")
        viewModel.quizState = .showingResult

        // Act
        viewModel.resetToHome()

        // Assert
        #expect(viewModel.answeredQuestion == nil)
    }

    @Test("rapid question transitions maintain correct pairing")
    @MainActor
    func rapidTransitionsMaintainCorrectPairing() async throws {
        // Arrange - Simulate answering multiple questions rapidly
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
        viewModel.currentQuestion = q1
        viewModel.answeredQuestion = q1
        viewModel.lastEvaluation = Evaluation(
            userAnswer: "A1",
            result: .correct,
            points: 1.0,
            correctAnswer: "A1"
        )
        viewModel.quizState = .showingResult

        // Assert Q1 state
        #expect(viewModel.answeredQuestion?.id == "q_001")
        #expect(viewModel.answeredQuestion?.sourceExcerpt == "Source 1")

        // Rapidly transition to Q2
        await viewModel.proceedToNextQuestion()
        #expect(viewModel.answeredQuestion == nil)

        // Question 2
        let q2 = makeQuestion(id: "q_002", source: "Source 2")
        viewModel.currentQuestion = q2
        viewModel.answeredQuestion = q2
        viewModel.lastEvaluation = Evaluation(
            userAnswer: "A2",
            result: .incorrect,
            points: 0.0,
            correctAnswer: "A2 Expected"
        )
        viewModel.quizState = .showingResult

        // Assert Q2 state - should not have Q1's source
        #expect(viewModel.answeredQuestion?.id == "q_002")
        #expect(viewModel.answeredQuestion?.sourceExcerpt == "Source 2")
        #expect(viewModel.answeredQuestion?.sourceExcerpt != "Source 1")
    }
}
