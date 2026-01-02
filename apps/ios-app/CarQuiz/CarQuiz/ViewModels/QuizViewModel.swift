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

    // NEW: Auto-advance countdown for ResultView binding (single source of truth)
    @Published var autoAdvanceCountdown: Int = 0

    // Auto-advance enabled state (permanently disabled when user pauses)
    @Published var autoAdvanceEnabled: Bool = true

    // Minimize state
    @Published var isMinimized: Bool = false

    // MARK: - Quiz Settings

    @Published var settings: QuizSettings = .default
    @Published var showingLanguagePicker = false

    // Computed properties for backward compatibility
    var selectedLanguage: Language {
        Language.forCode(settings.language) ?? Language.default
    }

    var selectedAudioMode: AudioMode {
        AudioMode.forId(settings.audioMode) ?? AudioMode.default
    }

    /// Whether minimize is allowed in current state
    /// Only enabled during .askingQuestion (not during recording/processing)
    var canMinimize: Bool {
        quizState == .askingQuestion
    }

    // MARK: - State Coordination Actor

    /// Actor to serialize state transitions and prevent concurrent handleQuizResponse calls
    private actor StateCoordinator {
        private var isProcessing = false

        func acquireLock() async -> Bool {
            guard !isProcessing else { return false }
            isProcessing = true
            return true
        }

        func releaseLock() {
            isProcessing = false
        }
    }

    private let stateCoordinator = StateCoordinator()

    // MARK: - Dependencies

    private let networkService: NetworkServiceProtocol
    private let audioService: AudioServiceProtocol
    private let sessionStore: SessionStoreProtocol
    private let questionHistoryStore: QuestionHistoryStoreProtocol

    private var cancellables = Set<AnyCancellable>()

    // Auto-advance task for result screen
    private var autoAdvanceTask: Task<Void, Never>?

    // Next question data (from response, displayed after showing results)
    private var nextQuestionAudioUrl: String?
    private var nextQuestion: Question?

    // MARK: - Initialization

    init(
        networkService: NetworkServiceProtocol,
        audioService: AudioServiceProtocol,
        sessionStore: SessionStoreProtocol,
        questionHistoryStore: QuestionHistoryStoreProtocol
    ) {
        self.networkService = networkService
        self.audioService = audioService
        self.sessionStore = sessionStore
        self.questionHistoryStore = questionHistoryStore

        // Load saved settings
        self.settings = sessionStore.loadSettings()
    }

    // MARK: - Quiz Flow

    /// Start a new quiz session
    func startNewQuiz(
        maxQuestions: Int? = nil,
        difficulty: String? = nil,
        language: String? = nil
    ) async {
        isLoading = true
        errorMessage = nil
        autoAdvanceEnabled = true  // Reset auto-advance for new quiz

        defer { isLoading = false }

        // Use provided parameters or fall back to settings
        let quizMaxQuestions = maxQuestions ?? settings.numberOfQuestions
        let quizDifficulty = difficulty ?? settings.difficulty
        let quizLanguage = language ?? settings.language

        // Check if question history is at capacity
        if questionHistoryStore.isAtCapacity {
            errorMessage = "Question history is full. Please reset your history in Settings to continue."
            quizState = .error
            return
        }

        do {
            if Config.verboseLogging {
                print("🎮 Starting new quiz: \(quizMaxQuestions) questions, difficulty: \(quizDifficulty), language: \(quizLanguage)")
            }

            // Get excluded question IDs from history
            let excludedIds = questionHistoryStore.getExclusionList()

            if Config.verboseLogging {
                print("🎮 Excluding \(excludedIds.count) previously seen questions")
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
                maxQuestions: quizMaxQuestions,
                difficulty: quizDifficulty,
                language: quizLanguage,
                category: settings.category
            )

            currentSession = session
            sessionStore.saveSession(id: session.id)
            // Settings are already persisted in SessionStore, no need to save individually

            // Start quiz and get first question with exclusion list
            let response = try await networkService.startQuiz(
                sessionId: session.id,
                excludedQuestionIds: excludedIds
            )

            currentSession = response.session
            currentQuestion = response.currentQuestion
            quizState = .askingQuestion

            // Save question ID to history
            if let questionId = response.currentQuestion?.id {
                do {
                    try questionHistoryStore.addQuestionId(questionId)
                } catch QuestionHistoryError.capacityReached {
                    // Should not happen (checked before quiz start)
                    if Config.verboseLogging {
                        print("⚠️ WARNING: Question history reached capacity mid-quiz")
                    }
                } catch {
                    if Config.verboseLogging {
                        print("⚠️ WARNING: Failed to save question to history: \(error)")
                    }
                }
            }

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
    /// (Kept for backward compatibility - settings are now loaded in init)
    func loadSavedLanguage() {
        settings = sessionStore.loadSettings()

        if Config.verboseLogging {
            print("📦 Reloaded settings (language: \(settings.language))")
        }
    }

    /// Load saved audio mode preference from storage
    /// (Kept for backward compatibility - settings are now loaded in init)
    func loadSavedAudioMode() {
        settings = sessionStore.loadSettings()

        if Config.verboseLogging {
            print("📦 Reloaded settings (audio mode: \(settings.audioMode))")
        }
    }

    /// Save current settings to persistent storage
    func saveSettings() {
        sessionStore.saveSettings(settings)

        if Config.verboseLogging {
            print("💾 Saved settings: \(settings)")
        }
    }

    /// Pause the quiz (permanently disables auto-advance for this session)
    func pauseQuiz() {
        autoAdvanceTask?.cancel()
        autoAdvanceTask = nil
        autoAdvanceEnabled = false

        if Config.verboseLogging {
            print("⏸️ Quiz paused - auto-advance permanently disabled for this session")
        }
    }

    /// Resume the quiz (proceeds to next question immediately, no auto-advance)
    func resumeQuiz() {
        Task {
            await proceedToNextQuestion()
        }

        if Config.verboseLogging {
            print("▶️ Quiz resumed - proceeding to next question")
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
                settings.audioMode = newMode.id
                sessionStore.saveSettings(settings)

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
        // Note: selectedLanguage is a computed property from settings
        // If using language picker, it should update settings.language directly
        Task {
            await startNewQuiz()
        }
    }

    // MARK: - Private Helpers

    /// Stop any currently playing audio (cleanup during state transitions)
    private func stopAnyPlayingAudio() async {
        await audioService.stopPlayback()

        if Config.verboseLogging {
            print("🔇 Stopped any playing audio for state transition")
        }
    }

    private func handleQuizResponse(_ response: QuizResponse) async {
        // CRITICAL: Acquire lock to prevent concurrent calls
        guard await stateCoordinator.acquireLock() else {
            if Config.verboseLogging {
                print("⚠️ handleQuizResponse already in progress, ignoring duplicate call")
            }
            return
        }

        defer {
            Task {
                await stateCoordinator.releaseLock()
            }
        }

        // Cancel any previous auto-advance task
        autoAdvanceTask?.cancel()
        autoAdvanceTask = nil

        // Update session state
        currentSession = response.session
        lastEvaluation = response.evaluation

        // Update score and question count
        if let participant = response.session.participants.first {
            score = participant.score
            questionsAnswered = participant.answeredCount
        }

        // Store NEXT question separately (don't update currentQuestion yet!)
        // This prevents the next question from flashing before showing results
        nextQuestion = response.currentQuestion
        nextQuestionAudioUrl = response.audio?.questionUrl

        // Save question ID to history
        if let questionId = response.currentQuestion?.id {
            do {
                try questionHistoryStore.addQuestionId(questionId)
            } catch QuestionHistoryError.capacityReached {
                // Should not happen (checked before quiz start)
                if Config.verboseLogging {
                    print("⚠️ WARNING: Question history reached capacity mid-quiz")
                }
            } catch {
                if Config.verboseLogging {
                    print("⚠️ WARNING: Failed to save question to history: \(error)")
                }
            }
        }

        // Play feedback audio (non-blocking, but await to get duration)
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

        // Start auto-advance with countdown (using user's settings)
        await startAutoAdvanceCountdown(duration: settings.autoAdvanceDelay, audioDuration: feedbackDuration)
    }

    /// Starts the auto-advance countdown loop with real-time UI updates
    private func startAutoAdvanceCountdown(duration: Int, audioDuration: TimeInterval) async {
        // Skip auto-advance if permanently disabled by user pause
        guard autoAdvanceEnabled else {
            if Config.verboseLogging {
                print("⏱️ Auto-advance disabled, skipping countdown")
            }
            autoAdvanceCountdown = 0
            return
        }

        if Config.verboseLogging {
            print("⏱️ Auto-advancing in \(duration)s (audio: \(String(format: "%.1f", audioDuration))s, reading time + buffer)")
        }

        autoAdvanceCountdown = duration

        autoAdvanceTask = Task { [weak self] in
            guard let self else { return }

            // Countdown loop
            for remaining in (0...duration).reversed() {
                // Check for cancellation
                if Task.isCancelled {
                    if Config.verboseLogging {
                        await MainActor.run {
                            print("⏱️ Auto-advance countdown cancelled")
                        }
                    }
                    return
                }

                await MainActor.run {
                    self.autoAdvanceCountdown = remaining
                }

                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second
                }
            }

            // Auto-advance after countdown completes
            if Task.isCancelled { return }

            await MainActor.run {
                guard self.quizState == .showingResult else {
                    if Config.verboseLogging {
                        print("⏱️ Auto-advance aborted - not in showingResult state")
                    }
                    return
                }

                Task {
                    await self.proceedToNextQuestion()
                }
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

        // CRITICAL: Stop any playing feedback audio before transitioning
        // This ensures clean state transition from ResultView to QuestionView
        await stopAnyPlayingAudio()

        // Small delay to ensure audio cleanup completes
        try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1 seconds

        // Determine next state based on session status
        if let session = currentSession, session.isFinished {
            // Quiz is complete
            quizState = .finished
            sessionStore.clearSession()

            if Config.verboseLogging {
                print("🎮 Quiz finished! Final score: \(score)")
            }
        } else {
            // More questions remain - NOW update currentQuestion with stored next question
            // This ensures the next question only appears AFTER showing results
            currentQuestion = nextQuestion
            nextQuestion = nil  // Clear after use

            // Transition to asking question state
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
        // Cancel any pending auto-advance task
        autoAdvanceTask?.cancel()
        autoAdvanceTask = nil

        // Stop any playing audio
        Task {
            await stopAnyPlayingAudio()
        }

        // Reset all state
        quizState = .idle
        currentQuestion = nil
        currentSession = nil
        lastEvaluation = nil
        score = 0.0
        questionsAnswered = 0
        errorMessage = nil
        nextQuestionAudioUrl = nil
        nextQuestion = nil
        autoAdvanceCountdown = 0
    }

    // MARK: - Question History Management

    /// Number of questions in history
    var questionHistoryCount: Int {
        questionHistoryStore.askedQuestionIds.count
    }

    /// Reset question history (allows previously seen questions to appear again)
    func resetQuestionHistory() {
        questionHistoryStore.clearHistory()

        if Config.verboseLogging {
            print("🗑️ Question history reset by user")
        }
    }
}

// MARK: - Preview Helpers

#if DEBUG
extension QuizViewModel {
    static let preview: QuizViewModel = {
        let viewModel = QuizViewModel(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            sessionStore: MockSessionStore(),
            questionHistoryStore: MockQuestionHistoryStore()
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
            sessionStore: MockSessionStore(),
            questionHistoryStore: MockQuestionHistoryStore()
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
