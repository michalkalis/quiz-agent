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

/// Error context for distinguishing error types
enum ErrorContext {
    case initialization  // Error during session creation or quiz start
    case submission      // Error during answer submission
    case general         // Other errors
}

/// Main quiz view model coordinating all services
@MainActor
final class QuizViewModel: ObservableObject {
    // MARK: - Published State

    @Published var quizState: QuizState = .idle
    @Published var currentQuestion: Question?
    @Published var currentSession: QuizSession?
    @Published var lastEvaluation: Evaluation?
    @Published var answeredQuestion: Question?  // Snapshot of question being evaluated (stable during ResultView)
    @Published var score: Double = 0.0
    @Published var questionsAnswered: Int = 0
    @Published var errorMessage: String?
    private var errorContext: ErrorContext = .initialization

    // Answer confirmation modal state
    @Published var showAnswerConfirmation = false
    @Published var transcribedAnswer = ""
    private var pendingResponse: QuizResponse? = nil

    // NEW: Auto-advance countdown for ResultView binding (single source of truth)
    @Published var autoAdvanceCountdown: Int = 0

    // Auto-advance enabled state (global setting toggle)
    @Published var autoAdvanceEnabled: Bool = true

    // Per-question pause state (resets on next question)
    @Published var currentQuestionPaused: Bool = false

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

    // MARK: - Audio Device State

    /// Available input devices from AudioService
    var availableInputDevices: [AudioDevice] {
        audioService.availableInputDevices
    }

    /// Currently selected input device (nil = automatic)
    var selectedInputDevice: AudioDevice? {
        audioService.currentInputDevice
    }

    /// Current output device name for display
    var currentOutputDeviceName: String {
        audioService.currentOutputDeviceName
    }

    /// Display name for current input device
    var currentInputDeviceName: String {
        if let device = audioService.currentInputDevice {
            return device.name
        }
        return "Automatic"
    }

    /// Sheet presentation state for microphone picker
    @Published var showingMicrophonePicker = false

    /// Whether minimize is allowed in current state
    /// Enabled during active quiz states (question, recording, processing, results)
    var canMinimize: Bool {
        quizState == .askingQuestion || quizState == .recording || quizState == .processing || quizState == .showingResult
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
        errorMessage = nil
        autoAdvanceEnabled = true  // Reset auto-advance for new quiz

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
            errorContext = .initialization
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
            quizState = .error
            return
        }

        quizState = .processing
        errorMessage = nil

        do {
            if Config.verboseLogging {
                print("🎤 Submitting voice answer: \(audioData.count) bytes")
            }

            let response = try await networkService.submitVoiceAnswer(
                sessionId: sessionId,
                audioData: audioData,
                fileName: "answer.m4a"
            )

            // Check if response has a valid evaluation before showing confirmation
            guard let evaluation = response.evaluation else {
                if Config.verboseLogging {
                    print("⚠️ No evaluation in response - speech may not have been recognized")
                }
                // Return to asking state so user can re-record
                errorMessage = "Could not understand your answer. Please speak clearly and try again."
                errorContext = .submission
                quizState = .error
                return
            }

            // Store response and show confirmation modal
            pendingResponse = response
            transcribedAnswer = evaluation.userAnswer
            showAnswerConfirmation = true

            // Don't call handleQuizResponse yet - wait for user confirmation

        } catch let error as NetworkError {
            // Handle "speech not understood" errors gracefully - let user re-record
            if case .serverError(let statusCode, let message) = error, statusCode == 400 {
                errorMessage = message
                quizState = .askingQuestion  // Return to ready state for re-recording

                if Config.verboseLogging {
                    print("⚠️ Speech not understood, returning to question: \(message)")
                }
                return
            }

            // Other network errors go to error screen
            errorMessage = "Failed to submit answer: \(error.localizedDescription)"
            errorContext = .submission
            quizState = .error

            if Config.verboseLogging {
                print("❌ Error submitting answer: \(error)")
            }
        } catch {
            errorMessage = "Failed to submit answer: \(error.localizedDescription)"
            errorContext = .submission
            quizState = .error

            if Config.verboseLogging {
                print("❌ Error submitting answer: \(error)")
            }
        }
    }

    /// Confirm the transcribed answer and proceed to show result
    func confirmAnswer() async {
        guard let response = pendingResponse else { return }
        showAnswerConfirmation = false
        pendingResponse = nil
        await handleQuizResponse(response)
    }

    /// Reject the transcribed answer and return to ready-to-record state
    func rerecordAnswer() {
        showAnswerConfirmation = false
        pendingResponse = nil
        quizState = .askingQuestion  // Return to ready state, not recording
        errorMessage = nil
    }

    /// Whether to retry with a new session (for initialization errors)
    var shouldRetryWithNewSession: Bool {
        errorContext == .initialization
    }

    /// Retry the last operation based on error context
    func retryLastOperation() async {
        switch errorContext {
        case .submission:
            // Retry answer submission (return to recording state)
            quizState = .askingQuestion
            errorMessage = nil
        default:
            // Fallback to starting new quiz
            await startNewQuiz()
        }
    }

    /// Resubmit an edited text answer
    func resubmitAnswer(_ newAnswer: String) async {
        guard let sessionId = currentSession?.id else {
            errorMessage = "No active session"
            return
        }

        quizState = .processing
        errorMessage = nil

        do {
            if Config.verboseLogging {
                print("✏️ Resubmitting edited answer: \(newAnswer)")
            }

            let response = try await networkService.submitTextInput(
                sessionId: sessionId,
                input: newAnswer,
                audio: settings.audioMode != "off"
            )

            await handleQuizResponse(response)

        } catch {
            errorMessage = "Failed to resubmit answer: \(error.localizedDescription)"
            quizState = .error

            if Config.verboseLogging {
                print("❌ Error resubmitting answer: \(error)")
            }
        }
    }

    /// Skip the current question
    func skipQuestion() async {
        guard let sessionId = currentSession?.id else { return }

        quizState = .processing
        errorMessage = nil

        do {
            if Config.verboseLogging {
                print("⏭️ Skipping current question")
            }

            let response = try await networkService.submitTextInput(
                sessionId: sessionId,
                input: "skip",
                audio: settings.audioMode != "off"
            )

            await handleQuizResponse(response)
        } catch {
            errorMessage = "Failed to skip question: \(error.localizedDescription)"
            errorContext = .submission
            quizState = .error

            if Config.verboseLogging {
                print("❌ Error skipping question: \(error)")
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

    /// Pause auto-advance for current question only (not permanent)
    func pauseQuiz() {
        autoAdvanceTask?.cancel()
        autoAdvanceTask = nil
        currentQuestionPaused = true

        if Config.verboseLogging {
            print("⏸️ Current question paused - auto-advance will resume on next question")
        }
    }

    /// Continue to next question after user paused current one
    func continueToNext() {
        // Reset per-question pause state
        currentQuestionPaused = false

        Task {
            await proceedToNextQuestion()
        }

        if Config.verboseLogging {
            print("▶️ Continuing to next question - auto-advance re-enabled")
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

    // MARK: - Audio Device Management

    /// Refresh available audio input devices
    func refreshAudioDevices() {
        audioService.refreshAvailableDevices()

        // Try to restore saved preferred device
        if let savedId = settings.preferredInputDeviceId {
            // Check if saved device is still available
            if let device = availableInputDevices.first(where: { $0.id == savedId }) {
                do {
                    try audioService.setPreferredInputDevice(device)
                    if Config.verboseLogging {
                        print("🎤 Restored preferred input device: \(device.name)")
                    }
                } catch {
                    if Config.verboseLogging {
                        print("⚠️ Failed to restore preferred input device: \(error)")
                    }
                }
            } else {
                // Saved device not available, keep preference for reconnection
                if Config.verboseLogging {
                    print("🎤 Saved input device not available, using automatic")
                }
            }
        }
    }

    /// Set preferred input device
    /// - Parameter device: Device to use, or nil for automatic selection
    func setPreferredInputDevice(_ device: AudioDevice?) {
        do {
            try audioService.setPreferredInputDevice(device)

            // Persist preference
            settings.preferredInputDeviceId = device?.id
            sessionStore.saveSettings(settings)

            if Config.verboseLogging {
                let deviceName = device?.name ?? "Automatic"
                print("🎤 Set preferred input device: \(deviceName)")
            }
        } catch {
            errorMessage = "Failed to set audio device: \(error.localizedDescription)"

            if Config.verboseLogging {
                print("❌ Error setting preferred input device: \(error)")
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

        // CRITICAL: Validate evaluation exists before showing result
        guard let evaluation = response.evaluation else {
            if Config.verboseLogging {
                print("❌ ERROR: No evaluation in response, cannot show result")
            }
            errorMessage = "Could not evaluate your answer. Please try again."
            errorContext = .submission
            quizState = .error
            return
        }

        // CRITICAL: Snapshot the current question BEFORE updating any state
        // This ensures ResultView displays the correct source attribution
        // for the question being evaluated (not the next question)
        answeredQuestion = currentQuestion

        lastEvaluation = evaluation

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

        // IMPORTANT: Show result screen BEFORE playing audio
        // This ensures ResultView is visible when audio starts playing
        quizState = .showingResult

        // Play feedback audio and start countdown in background
        Task {
            var feedbackDuration: TimeInterval = 0.0

            if let audioInfo = response.audio {
                // Prioritize base64 (enhanced feedback) over URL (generic feedback)
                if let base64 = audioInfo.feedbackAudioBase64 {
                    feedbackDuration = await playFeedbackAudioBase64(base64)
                } else if let feedbackUrl = audioInfo.feedbackUrl {
                    feedbackDuration = await playFeedbackAudio(from: feedbackUrl)
                }
            }

            // Start auto-advance countdown after audio completes (or immediately if no audio)
            await startAutoAdvanceCountdown(duration: settings.autoAdvanceDelay, audioDuration: feedbackDuration)
        }
    }

    /// Starts the auto-advance countdown loop with real-time UI updates
    private func startAutoAdvanceCountdown(duration: Int, audioDuration: TimeInterval) async {
        // Skip auto-advance if disabled globally OR if current question is paused
        guard autoAdvanceEnabled && !currentQuestionPaused else {
            if Config.verboseLogging {
                let reason = !autoAdvanceEnabled ? "disabled globally" : "paused for current question"
                print("⏱️ Auto-advance skipped (\(reason))")
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

        // Reset per-question pause when moving to next question
        currentQuestionPaused = false

        // Clear the answered question snapshot (no longer needed after result screen)
        answeredQuestion = nil

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
        answeredQuestion = nil
        score = 0.0
        questionsAnswered = 0
        errorMessage = nil
        nextQuestionAudioUrl = nil
        nextQuestion = nil
        autoAdvanceCountdown = 0
        currentQuestionPaused = false
        autoAdvanceEnabled = true
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
        viewModel.settings.audioMode = AudioMode.default.id
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
        viewModel.answeredQuestion = Question.preview  // Snapshot for result screen
        viewModel.lastEvaluation = Evaluation.previewCorrect
        viewModel.score = 1.0
        viewModel.questionsAnswered = 1
        viewModel.quizState = .showingResult
        viewModel.settings.audioMode = AudioMode.default.id
        return viewModel
    }()
}
#endif
