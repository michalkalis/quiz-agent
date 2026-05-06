//
//  Fixtures.swift
//  HangsTests
//
//  Shared test fixtures and factory functions for QuizViewModelTests.
//  Eliminates duplicated makeViewModel helpers across test suites.
//

import Foundation
@testable import Hangs

// MARK: - Fixtures

@MainActor
enum Fixtures {

    // MARK: - Model Factories

    /// Returns a `QuizSession` populated with a single participant.
    static func makeQuizSession(
        id: String = "test_session_123",
        phase: String = "asking",
        maxQuestions: Int = 10
    ) -> QuizSession {
        QuizSession(
            id: id,
            mode: "single",
            phase: phase,
            maxQuestions: maxQuestions,
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
    }

    /// Returns a `QuizSession` with no participants (lightweight session for currentSession injection).
    static func makeActiveSession(
        id: String = "test_session_123",
        phase: String = "asking",
        maxQuestions: Int = 10
    ) -> QuizSession {
        QuizSession(
            id: id,
            mode: "single",
            phase: phase,
            maxQuestions: maxQuestions,
            currentDifficulty: "medium",
            category: nil,
            language: "en",
            participants: [],
            expiresAt: Date().addingTimeInterval(30 * 60),
            createdAt: Date()
        )
    }

    /// Returns a `Question` with sensible defaults for testing.
    static func makeQuestion(
        id: String = "q_001",
        text: String = "What is 2+2?",
        source: String = "Test Source",
        correctAnswer: String = "4"
    ) -> Question {
        Question(
            id: id,
            question: text,
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

    /// Returns `QuizSettings` with sensible defaults for testing.
    static func makeQuizSettings() -> QuizSettings {
        QuizSettings.default
    }

    // MARK: - Mock Network Factory

    /// Returns a `MockNetworkService` pre-seeded with a `QuizSession` and a
    /// happy-path `QuizResponse`. Customise via `configure` closure.
    static func makeFullMockNetwork(
        sessionId: String = "test_session_123",
        configure: (MockNetworkService) -> Void = { _ in }
    ) -> MockNetworkService {
        let mock = MockNetworkService()
        mock.mockSession = makeQuizSession(id: sessionId)
        mock.mockResponse = QuizResponse(
            success: true,
            message: "Input processed",
            session: makeQuizSession(id: sessionId, phase: "asking"),
            currentQuestion: makeQuestion(id: "q_002", text: "Next question?", source: "Next"),
            evaluation: Evaluation(
                userAnswer: "Test",
                result: .correct,
                points: 1.0,
                correctAnswer: "Expected Answer",
                questionId: "q_001",
                explanation: nil
            ),
            feedbackReceived: ["answer: correct"],
            audio: nil
        )
        configure(mock)
        return mock
    }

    // MARK: - ViewModel Factories

    /// Simple ViewModel with default fresh mocks — no session or question pre-seeded.
    static func makeViewModel() -> QuizViewModel {
        QuizViewModel(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
    }

    /// ViewModel wired to a network mock pre-seeded with a session and happy-path response.
    /// Pass `shouldFail: true` to make all network calls throw.
    /// Returns `(viewModel, mockNetwork)` so callers can assert on the network mock.
    static func makeViewModelWithNetwork(
        shouldFail: Bool = false,
        configure: (MockNetworkService) -> Void = { _ in }
    ) -> (QuizViewModel, MockNetworkService) {
        let mockNetwork = makeFullMockNetwork(configure: { mock in
            mock.shouldFail = shouldFail
            configure(mock)
        })
        let viewModel = QuizViewModel(
            networkService: mockNetwork,
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        return (viewModel, mockNetwork)
    }

    /// ViewModel wired to an audio mock with optional recording-failure injection.
    /// Also seeds the network mock so network-dependent flows succeed.
    /// Returns `(viewModel, mockAudio)` so callers can assert on the audio mock.
    static func makeViewModelWithAudio(
        shouldFailRecording: Bool = false
    ) -> (QuizViewModel, MockAudioService) {
        let mockAudio = MockAudioService()
        mockAudio.shouldFailRecording = shouldFailRecording
        let mockNetwork = makeFullMockNetwork()
        let viewModel = QuizViewModel(
            networkService: mockNetwork,
            audioService: mockAudio,
            persistenceStore: MockPersistenceStore()
        )
        return (viewModel, mockAudio)
    }

    /// ViewModel wired to a persistence mock.
    /// Returns `(viewModel, mockStore)` so callers can assert on save counts / saved values.
    static func makeViewModelWithPersistence() -> (QuizViewModel, MockPersistenceStore) {
        let mockStore = MockPersistenceStore()
        let viewModel = QuizViewModel(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: mockStore
        )
        return (viewModel, mockStore)
    }

    /// ViewModel pre-configured for answer-timer tests:
    /// `currentQuestion` and `quizState = .askingQuestion` are set on the returned model.
    static func makeViewModelForTimerTests() -> QuizViewModel {
        let viewModel = QuizViewModel(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        viewModel.currentQuestion = makeQuestion(id: "q_001", source: "Test")
        viewModel.quizState = .askingQuestion
        return viewModel
    }
}
