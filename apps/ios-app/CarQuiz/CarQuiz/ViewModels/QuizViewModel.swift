//
//  QuizViewModel.swift
//  CarQuiz
//
//  Core quiz flow and state management
//

import Foundation
import Combine

/// Quiz state machine
enum QuizState: Equatable, Sendable {
    case idle
    case askingQuestion
    case recording
    case processing
    case showingResult
    case finished
    case error
}

/// Main quiz view model coordinating all services
@MainActor
final class QuizViewModel: ObservableObject {
    // MARK: - Published State

    @Published var quizState: QuizState = .idle
    @Published var currentQuestion: Question?
    @Published var currentSession: QuizSession?
    @Published var lastEvaluation: Evaluation?
    @Published var score: Double = 0.0
    @Published var questionsAnswered: Int = 0
    @Published var errorMessage: String?
    @Published var isLoading = false

    // MARK: - Dependencies

    private let networkService: NetworkServiceProtocol
    private let audioService: AudioServiceProtocol
    private let sessionStore: SessionStoreProtocol

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init(
        networkService: NetworkServiceProtocol,
        audioService: AudioServiceProtocol,
        sessionStore: SessionStoreProtocol
    ) {
        self.networkService = networkService
        self.audioService = audioService
        self.sessionStore = sessionStore
    }

    // MARK: - Quiz Flow

    /// Start a new quiz session
    func startNewQuiz(maxQuestions: Int = Config.defaultQuestions, difficulty: String = Config.defaultDifficulty) async {
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        do {
            if Config.verboseLogging {
                print("🎮 Starting new quiz: \(maxQuestions) questions, difficulty: \(difficulty)")
            }

            // Create session
            let session = try await networkService.createSession(
                maxQuestions: maxQuestions,
                difficulty: difficulty
            )

            currentSession = session
            sessionStore.saveSession(id: session.id)

            // Start quiz and get first question
            let response = try await networkService.startQuiz(sessionId: session.id)

            currentSession = response.session
            currentQuestion = response.currentQuestion
            quizState = .askingQuestion

            // Play question audio if available
            if let audioInfo = response.audio,
               let questionUrl = audioInfo.questionUrl {
                await playQuestionAudio(from: questionUrl)
            }

        } catch {
            errorMessage = "Failed to start quiz: \(error.localizedDescription)"
            quizState = .error

            if Config.verboseLogging {
                print("❌ Error starting quiz: \(error)")
            }
        }
    }

    /// Submit a voice answer
    func submitVoiceAnswer(audioData: Data) async {
        guard let sessionId = currentSession?.id else {
            errorMessage = "No active session"
            return
        }

        quizState = .processing
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        do {
            if Config.verboseLogging {
                print("🎤 Submitting voice answer: \(audioData.count) bytes")
            }

            let response = try await networkService.submitVoiceAnswer(
                sessionId: sessionId,
                audioData: audioData,
                fileName: "answer.m4a"
            )

            await handleQuizResponse(response)

        } catch {
            errorMessage = "Failed to submit answer: \(error.localizedDescription)"
            quizState = .error

            if Config.verboseLogging {
                print("❌ Error submitting answer: \(error)")
            }
        }
    }

    /// End the current quiz session
    func endQuiz() async {
        guard let sessionId = currentSession?.id else { return }

        do {
            try await networkService.endSession(sessionId: sessionId)
            sessionStore.clearSession()
            resetState()

            if Config.verboseLogging {
                print("🎮 Quiz ended")
            }
        } catch {
            errorMessage = "Failed to end quiz: \(error.localizedDescription)"

            if Config.verboseLogging {
                print("❌ Error ending quiz: \(error)")
            }
        }
    }

    /// Resume a saved session
    func resumeSession() async {
        guard sessionStore.currentSessionId != nil else {
            errorMessage = "No saved session found"
            return
        }

        // For now, just start a new quiz
        // In a full implementation, we'd fetch the session state from backend
        await startNewQuiz()
    }

    /// Reset to home screen immediately (without network call)
    func resetToHome() {
        sessionStore.clearSession()
        resetState()

        if Config.verboseLogging {
            print("🏠 Reset to home")
        }
    }

    // MARK: - Private Helpers

    private func handleQuizResponse(_ response: QuizResponse) async {
        currentSession = response.session
        lastEvaluation = response.evaluation

        // Update score and question count
        if let participant = response.session.participants.first {
            score = participant.score
            questionsAnswered = participant.answeredCount
        }

        // Play feedback audio
        if let audioInfo = response.audio,
           let feedbackUrl = audioInfo.feedbackUrl {
            await playFeedbackAudio(from: feedbackUrl)
        }

        // Check if quiz is finished
        if response.isQuizFinished {
            quizState = .finished
            sessionStore.clearSession()

            if Config.verboseLogging {
                print("🎮 Quiz finished! Final score: \(score)")
            }
            return
        }

        // Show result briefly
        quizState = .showingResult

        // Auto-advance to next question after delay
        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds

        // Check if still in showingResult state (user didn't navigate away)
        if quizState == .showingResult {
            currentQuestion = response.currentQuestion
            quizState = .askingQuestion

            // Play next question audio
            if let audioInfo = response.audio,
               let questionUrl = audioInfo.questionUrl {
                await playQuestionAudio(from: questionUrl)
            }
        }
    }

    private func playQuestionAudio(from urlString: String) async {
        do {
            let audioData = try await networkService.downloadAudio(from: urlString)
            try await audioService.playOpusAudio(audioData)
        } catch {
            if Config.verboseLogging {
                print("⚠️ Failed to play question audio: \(error)")
            }
            // Don't fail the quiz if audio doesn't play
        }
    }

    private func playFeedbackAudio(from urlString: String) async {
        do {
            let audioData = try await networkService.downloadAudio(from: urlString)
            try await audioService.playOpusAudio(audioData)
        } catch {
            if Config.verboseLogging {
                print("⚠️ Failed to play feedback audio: \(error)")
            }
            // Don't fail the quiz if audio doesn't play
        }
    }

    private func resetState() {
        quizState = .idle
        currentQuestion = nil
        currentSession = nil
        lastEvaluation = nil
        score = 0.0
        questionsAnswered = 0
        errorMessage = nil
    }
}

// MARK: - Preview Helpers

#if DEBUG
extension QuizViewModel {
    static let preview: QuizViewModel = {
        let viewModel = QuizViewModel(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            sessionStore: MockSessionStore()
        )
        viewModel.currentQuestion = Question.preview
        viewModel.quizState = .askingQuestion
        return viewModel
    }()

    static let previewWithEvaluation: QuizViewModel = {
        let viewModel = QuizViewModel(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            sessionStore: MockSessionStore()
        )
        viewModel.currentQuestion = Question.preview
        viewModel.lastEvaluation = Evaluation.previewCorrect
        viewModel.score = 1.0
        viewModel.questionsAnswered = 1
        viewModel.quizState = .showingResult
        return viewModel
    }()
}
#endif
