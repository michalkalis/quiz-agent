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

    // MARK: - Language Selection

    @Published var selectedLanguage: Language = Language.default
    @Published var showingLanguagePicker = false

    // MARK: - Audio Mode Selection

    @Published var selectedAudioMode: AudioMode = AudioMode.default

    // MARK: - Dependencies

    private let networkService: NetworkServiceProtocol
    private let audioService: AudioServiceProtocol
    private let sessionStore: SessionStoreProtocol

    private var cancellables = Set<AnyCancellable>()

    // Auto-advance task for result screen
    private var autoAdvanceTask: Task<Void, Never>?

    // Next question audio URL (from response)
    private var nextQuestionAudioUrl: String?

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
    func startNewQuiz(
        maxQuestions: Int = Config.defaultQuestions,
        difficulty: String = Config.defaultDifficulty,
        language: String? = nil
    ) async {
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        do {
            // Use provided language or fall back to selected language
            let languageCode = language ?? selectedLanguage.id

            if Config.verboseLogging {
                print("🎮 Starting new quiz: \(maxQuestions) questions, difficulty: \(difficulty), language: \(languageCode)")
            }

            // Configure audio session with user's preferred mode
            do {
                try audioService.setupAudioSession(mode: selectedAudioMode)
                sessionStore.saveAudioMode(selectedAudioMode.id)

                if Config.verboseLogging {
                    print("🎤 Audio session configured with \(selectedAudioMode.name)")
                }
            } catch {
                // Log error but continue - audio might still work
                if Config.verboseLogging {
                    print("⚠️ Warning: Failed to configure audio session: \(error)")
                }
            }

            // Create session
            let session = try await networkService.createSession(
                maxQuestions: maxQuestions,
                difficulty: difficulty,
                language: languageCode
            )

            currentSession = session
            sessionStore.saveSession(id: session.id)
            sessionStore.saveLanguage(languageCode)

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

    // MARK: - Language Selection

    /// Load saved language preference from storage
    func loadSavedLanguage() {
        if let savedCode = sessionStore.preferredLanguage,
           let language = Language.forCode(savedCode) {
            selectedLanguage = language

            if Config.verboseLogging {
                print("📦 Loaded saved language: \(language.name)")
            }
        }
    }

    /// Load saved audio mode preference from storage
    func loadSavedAudioMode() {
        if let savedId = sessionStore.preferredAudioMode,
           let mode = AudioMode.forId(savedId) {
            selectedAudioMode = mode

            if Config.verboseLogging {
                print("📦 Loaded saved audio mode: \(mode.name)")
            }
        }
    }

    /// Toggle audio mode between Call Mode and Media Mode
    func toggleAudioMode() {
        Task {
            let newMode = selectedAudioMode.id == "call"
                ? AudioMode.forId("media")!
                : AudioMode.forId("call")!

            do {
                try await audioService.switchAudioMode(newMode)
                selectedAudioMode = newMode
                sessionStore.saveAudioMode(newMode.id)

                if Config.verboseLogging {
                    print("🔄 Switched to \(newMode.name)")
                }
            } catch {
                errorMessage = "Failed to switch audio mode: \(error.localizedDescription)"

                if Config.verboseLogging {
                    print("❌ Error switching audio mode: \(error)")
                }
            }
        }
    }

    /// Show the language picker sheet
    func showLanguagePicker() {
        showingLanguagePicker = true
    }

    /// Confirm language selection and start quiz
    func confirmLanguageAndStartQuiz() {
        showingLanguagePicker = false
        Task {
            await startNewQuiz(language: selectedLanguage.id)
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

        // Store next question and its audio URL for later use
        currentQuestion = response.currentQuestion
        nextQuestionAudioUrl = response.audio?.questionUrl

        // Play feedback audio and capture duration
        var feedbackDuration: TimeInterval = 3.0  // Default fallback

        if let audioInfo = response.audio {
            // Prioritize base64 (enhanced feedback) over URL (generic feedback)
            if let base64 = audioInfo.feedbackAudioBase64 {
                feedbackDuration = await playFeedbackAudioBase64(base64)
            } else if let feedbackUrl = audioInfo.feedbackUrl {
                feedbackDuration = await playFeedbackAudio(from: feedbackUrl)
            }
        }

        // Always show result screen first
        quizState = .showingResult

        // Fixed 8-second auto-advance delay (balances audio playback + reading time + buffer)
        let autoAdvanceDelay: TimeInterval = 8.0
        let delayNanos = UInt64(autoAdvanceDelay * 1_000_000_000)

        if Config.verboseLogging {
            print("⏱️ Auto-advancing in \(String(format: "%.1f", autoAdvanceDelay))s (audio: \(String(format: "%.1f", feedbackDuration))s, reading time + buffer)")
        }

        // Store task reference to allow cancellation if user taps "Continue" button
        autoAdvanceTask = Task {
            try? await Task.sleep(nanoseconds: delayNanos)

            // Only proceed if still showing result (user didn't tap button)
            if quizState == .showingResult {
                await proceedToNextQuestion()
            }
        }
    }

    /// Proceed to next question or finish quiz
    /// Can be called manually via button or automatically via timer
    func proceedToNextQuestion() async {
        // Cancel any pending auto-advance
        autoAdvanceTask?.cancel()
        autoAdvanceTask = nil

        // Only proceed if currently showing results
        guard quizState == .showingResult else {
            if Config.verboseLogging {
                print("⚠️ Ignoring proceedToNextQuestion - not in showingResult state")
            }
            return
        }

        // Determine next state based on session status
        if let session = currentSession, session.isFinished {
            // Quiz is complete
            quizState = .finished
            sessionStore.clearSession()

            if Config.verboseLogging {
                print("🎮 Quiz finished! Final score: \(score)")
            }
        } else {
            // More questions remain - transition to next question
            // (question already loaded in currentQuestion from handleQuizResponse)
            quizState = .askingQuestion

            // Play next question audio if available
            if let questionUrl = nextQuestionAudioUrl {
                await playQuestionAudio(from: questionUrl)
                nextQuestionAudioUrl = nil  // Clear after use
            }

            if Config.verboseLogging {
                print("❓ Showing next question: \(currentQuestion?.question ?? "unknown")")
            }
        }
    }

    private func playQuestionAudio(from urlString: String) async {
        do {
            let audioData = try await networkService.downloadAudio(from: urlString)
            _ = try await audioService.playOpusAudio(audioData)
        } catch {
            if Config.verboseLogging {
                print("⚠️ Failed to play question audio: \(error)")
            }
            // Don't fail the quiz if audio doesn't play
        }
    }

    private func playFeedbackAudio(from urlString: String) async -> TimeInterval {
        do {
            let audioData = try await networkService.downloadAudio(from: urlString)
            let duration = try await audioService.playOpusAudio(audioData)
            return duration
        } catch {
            if Config.verboseLogging {
                print("⚠️ Failed to play feedback audio: \(error)")
            }
            return 3.0  // Default fallback duration
        }
    }

    private func playFeedbackAudioBase64(_ base64: String) async -> TimeInterval {
        do {
            let duration = try await audioService.playOpusAudioFromBase64(base64)
            return duration
        } catch {
            if Config.verboseLogging {
                print("⚠️ Failed to play base64 feedback audio: \(error)")
            }
            return 3.0  // Default fallback duration
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
        viewModel.selectedAudioMode = AudioMode.default
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
        viewModel.selectedAudioMode = AudioMode.default
        return viewModel
    }()
}
#endif
