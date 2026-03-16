//
//  QuizViewModel.swift
//  CarQuiz
//
//  Core quiz flow and state management
//

import Foundation
import Combine

/// Error context for distinguishing error types
enum ErrorContext: Sendable {
    case initialization  // Error during session creation or quiz start
    case submission      // Error during answer submission
    case recording       // Error during audio recording
    case general         // Other errors
}

/// Quiz state machine
enum QuizState: Sendable {
    case idle
    case startingQuiz
    case askingQuestion
    case recording
    case processing
    case showingResult(question: Question, evaluation: Evaluation)
    case finished
    case error(message: String, context: ErrorContext)
}

// Custom Equatable: compares cases only (ignores associated values) to preserve animation behavior
extension QuizState: Equatable {
    static func == (lhs: QuizState, rhs: QuizState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.startingQuiz, .startingQuiz),
             (.askingQuestion, .askingQuestion),
             (.recording, .recording),
             (.processing, .processing),
             (.showingResult, .showingResult),
             (.finished, .finished),
             (.error, .error):
            return true
        default:
            return false
        }
    }
}

extension QuizState {
    var isShowingResult: Bool {
        if case .showingResult = self { return true }
        return false
    }

    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}

/// Main quiz view model coordinating all services
@MainActor
final class QuizViewModel: ObservableObject {
    // MARK: - Published State

    @Published var quizState: QuizState = .idle
    @Published var currentQuestion: Question?
    @Published var currentSession: QuizSession?
    @Published var score: Double = 0.0
    @Published var questionsAnswered: Int = 0
    @Published var errorMessage: String?  // Inline errors shown in QuestionView (e.g., recording failures)

    // Answer confirmation modal state
    @Published var showAnswerConfirmation = false
    @Published var transcribedAnswer = ""
    private var pendingResponse: QuizResponse? = nil

    // Auto-advance countdown for ResultView binding (single source of truth)
    @Published var autoAdvanceCountdown: Int = 0

    // Answer timer countdown (visible on QuestionView)
    @Published var answerTimerCountdown: Int = 0

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
        switch quizState {
        case .askingQuestion, .recording, .processing, .showingResult:
            return true
        default:
            return false
        }
    }

    // MARK: - Result Accessors (extract associated values for Views)

    /// The question being displayed on the result screen
    var resultQuestion: Question? {
        if case .showingResult(let question, _) = quizState { return question }
        return nil
    }

    /// The evaluation being displayed on the result screen
    var resultEvaluation: Evaluation? {
        if case .showingResult(_, let evaluation) = quizState { return evaluation }
        return nil
    }

    // MARK: - Re-entrancy Guard

    /// Simple Bool flag to prevent concurrent handleQuizResponse calls.
    /// Safe because this class is @MainActor — all access is serialized on the main thread.
    private var isProcessingResponse = false

    // MARK: - Voice Command State

    @Published var voiceCommandState: VoiceCommandListeningState = .disabled
    private var voiceCommandTask: Task<Void, Never>?
    private var bargeInTask: Task<Void, Never>?

    // MARK: - Auto-Record State

    /// Whether auto-record is active for the current recording (for UI hints)
    @Published var isAutoRecording: Bool = false

    /// Whether speech has been detected during auto-record (for UI hints)
    @Published var speechDetectedDuringAutoRecord: Bool = false

    // MARK: - Streaming STT State

    /// Live transcript from ElevenLabs (updates as user speaks)
    @Published var liveTranscript: String = ""

    /// Whether streaming STT is active
    @Published var isStreamingSTT: Bool = false

    // MARK: - Dependencies

    private let networkService: NetworkServiceProtocol
    private let audioService: AudioServiceProtocol
    private let persistenceStore: PersistenceStoreProtocol
    private let voiceCommandService: VoiceCommandServiceProtocol?
    private let sttService: ElevenLabsSTTServiceProtocol?

    private var cancellables = Set<AnyCancellable>()

    // Auto-advance task for result screen
    private var autoAdvanceTask: Task<Void, Never>?

    // Voice submission task for cancellation support
    private var voiceSubmissionTask: Task<Void, Never>?

    // Answer timer task (countdown before auto-recording)
    private var answerTimerTask: Task<Void, Never>?

    // Auto-stop recording task (stops recording after Config.autoRecordingDuration)
    private var autoStopRecordingTask: Task<Void, Never>?

    // Silence detection task (monitors speech activity during auto-record)
    private var silenceDetectionTask: Task<Void, Never>?

    // Streaming STT event listener task
    private var sttEventTask: Task<Void, Never>?

    // Streaming audio chunk sender task
    private var sttChunkTask: Task<Void, Never>?

    // Whether the current recording is a re-record (bypasses all timers)
    private var isRerecording: Bool = false

    // Next question data (from response, displayed after showing results)
    private var nextQuestionAudioUrl: String?
    private var nextQuestion: Question?

    // Current question audio URL for "repeat" command
    private var currentQuestionAudioUrl: String?

    // MARK: - Initialization

    init(
        networkService: NetworkServiceProtocol,
        audioService: AudioServiceProtocol,
        persistenceStore: PersistenceStoreProtocol,
        voiceCommandService: VoiceCommandServiceProtocol? = nil,
        sttService: ElevenLabsSTTServiceProtocol? = nil
    ) {
        self.networkService = networkService
        self.audioService = audioService
        self.persistenceStore = persistenceStore
        self.voiceCommandService = voiceCommandService
        self.sttService = sttService

        // Load saved settings
        self.settings = persistenceStore.loadSettings()

        // Auto-persist settings whenever they change
        $settings
            .dropFirst()          // Skip the initial value replayed by @Published
            .removeDuplicates()   // Only persist actual changes (QuizSettings is Equatable)
            .sink { [persistenceStore] in persistenceStore.saveSettings($0) }
            .store(in: &cancellables)
    }

    // MARK: - Quiz Flow

    /// Start a new quiz session
    func startNewQuiz(
        maxQuestions: Int? = nil,
        difficulty: String? = nil,
        language: String? = nil
    ) async {
        quizState = .startingQuiz
        errorMessage = nil
        autoAdvanceEnabled = true  // Reset auto-advance for new quiz
        isRerecording = false

        // Use provided parameters or fall back to settings
        let quizMaxQuestions = maxQuestions ?? settings.numberOfQuestions
        let quizDifficulty = difficulty ?? settings.difficulty
        let quizLanguage = language ?? settings.language

        // Check if question history is at capacity
        if persistenceStore.isAtCapacity {
            quizState = .error(
                message: "Question history is full. Please reset your history in Settings to continue.",
                context: .initialization
            )
            return
        }

        do {
            if Config.verboseLogging {
                print("🎮 Starting new quiz: \(quizMaxQuestions) questions, difficulty: \(quizDifficulty), language: \(quizLanguage)")
            }

            // Get excluded question IDs from history
            let excludedIds = persistenceStore.getExclusionList()

            if Config.verboseLogging {
                print("🎮 Excluding \(excludedIds.count) previously seen questions")
            }

            // Configure audio session with user's preferred mode
            do {
                try audioService.setupAudioSession(mode: selectedAudioMode)

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
            persistenceStore.saveSession(id: session.id)

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
                    try persistenceStore.addQuestionId(questionId)
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

            // Start voice command listening
            startVoiceCommands()

            // Play question audio if available
            if let audioInfo = response.audio,
               let questionUrl = audioInfo.questionUrl {
                await playQuestionAudio(from: questionUrl)
            } else {
                // No audio — auto-record or timer based on settings
                await startRecordingOrTimer()
            }

        } catch {
            quizState = .error(
                message: "Failed to start quiz: \(error.localizedDescription)",
                context: .initialization
            )

            if Config.verboseLogging {
                print("❌ Error starting quiz: \(error)")
            }
        }
    }

    // MARK: - Recording Lifecycle

    /// Toggle recording: start if asking a question, stop and submit if recording
    func toggleRecording() async {
        switch quizState {
        case .askingQuestion:
            cancelAnswerTimer()
            await startRecording()
        case .recording:
            cancelAutoStopRecordingTimer()
            await stopRecordingAndSubmit()
        default:
            break
        }
    }

    /// Start recording the user's voice answer
    /// Handles audio preparation, state transitions, and error rollback
    /// Routes to streaming STT (ElevenLabs) or batch M4A (Whisper) based on feature flag
    private func startRecording() async {
        cancelAnswerTimer()
        errorMessage = nil
        quizState = .recording
        voiceCommandService?.setRecordingActive(true)

        // Choose streaming STT or batch M4A based on feature flag
        if Config.useElevenLabsSTT && sttService != nil {
            await startStreamingRecording()
        } else {
            await startBatchRecording()
        }
    }

    /// Start batch M4A recording (original Whisper path)
    private func startBatchRecording() async {
        do {
            await audioService.prepareForRecording()
            try audioService.startRecording()

            if isAutoRecording, let service = voiceCommandService {
                speechDetectedDuringAutoRecord = false
                startSilenceDetection(service: service)
            }

            startAutoStopRecordingTimer()
        } catch {
            isAutoRecording = false
            speechDetectedDuringAutoRecord = false
            quizState = .askingQuestion
            errorMessage = "Recording failed: \(error.localizedDescription)"

            if Config.verboseLogging {
                print("❌ Recording failed to start: \(error)")
            }
        }
    }

    /// Start streaming recording with ElevenLabs Scribe v2 Realtime STT
    private func startStreamingRecording() async {
        guard let sttService else {
            // Fallback to batch if STT service unavailable
            await startBatchRecording()
            return
        }

        do {
            // 1. Get single-use token from backend
            let token = try await networkService.fetchElevenLabsToken()

            // 2. Connect to ElevenLabs WebSocket
            let languageCode = currentSession?.language ?? settings.language
            try await sttService.connect(token: token, languageCode: languageCode)

            // 3. Start listening for STT events
            liveTranscript = ""
            isStreamingSTT = true
            startSTTEventListener(sttService: sttService)

            // 4. Start PCM recording and stream chunks to WebSocket
            await audioService.prepareForRecording()
            let sttRef = sttService
            try audioService.startStreamingRecording { pcmData in
                Task {
                    try? await sttRef.sendAudioChunk(pcmData)
                }
            }

            // 5. Start hard safety limit timer
            startAutoStopRecordingTimer()

            if Config.verboseLogging {
                print("🎙️ Streaming STT recording started")
            }

        } catch {
            // Fallback to batch recording on any setup failure
            isStreamingSTT = false
            liveTranscript = ""
            await sttService.disconnect()

            if Config.verboseLogging {
                print("⚠️ Streaming STT setup failed, falling back to batch: \(error)")
            }

            await startBatchRecording()
        }
    }

    /// Listen for STT events and update live transcript / handle committed text
    private func startSTTEventListener(sttService: ElevenLabsSTTServiceProtocol) {
        sttEventTask?.cancel()
        sttEventTask = Task { [weak self] in
            for await event in sttService.events {
                guard let self, !Task.isCancelled else { break }

                switch event {
                case .partialTranscript(let text):
                    self.liveTranscript = text

                case .committedTranscript(let text):
                    self.liveTranscript = text
                    // Auto-stop recording and submit the committed text
                    await self.handleCommittedTranscript(text)
                    return

                case .connected:
                    break // Already handled in startStreamingRecording

                case .disconnected(let error):
                    if self.isStreamingSTT {
                        if Config.verboseLogging {
                            print("⚠️ STT disconnected unexpectedly: \(error?.localizedDescription ?? "unknown")")
                        }
                        // If we were mid-recording, fall back gracefully
                        self.isStreamingSTT = false
                        self.liveTranscript = ""
                    }
                    return
                }
            }
        }
    }

    /// Handle committed transcript from ElevenLabs VAD
    private func handleCommittedTranscript(_ text: String) async {
        guard quizState == .recording else { return }

        // Stop streaming recording
        cancelAutoStopRecordingTimer()
        cancelSilenceDetection()
        voiceCommandService?.setRecordingActive(false)
        audioService.stopStreamingRecording()
        isAutoRecording = false
        speechDetectedDuringAutoRecord = false

        // Disconnect STT WebSocket
        sttEventTask?.cancel()
        sttEventTask = nil
        await sttService?.disconnect()
        isStreamingSTT = false

        if Config.verboseLogging {
            print("🎙️ Committed transcript: \(text)")
        }

        // Show confirmation modal with the transcribed text
        transcribedAnswer = text
        showAnswerConfirmation = true
        // Stay in .recording → switch to a neutral state for the modal
        quizState = .processing
    }

    /// Subscribe to silence events and auto-stop recording when silence threshold reached
    private func startSilenceDetection(service: VoiceCommandServiceProtocol) {
        cancelSilenceDetection()

        silenceDetectionTask = Task { [weak self] in
            for await event in service.silenceEvents {
                guard let self, !Task.isCancelled else { break }
                guard self.quizState == .recording else { continue }

                switch event {
                case .speechStarted:
                    self.speechDetectedDuringAutoRecord = true
                case .silenceAfterSpeech(let duration):
                    if Config.verboseLogging {
                        print("🔇 Auto-record: silence threshold reached (\(String(format: "%.1f", duration))s), auto-stopping")
                    }
                    await self.stopRecordingAndSubmit()
                    return
                }
            }
        }
    }

    /// Cancel silence detection subscription
    private func cancelSilenceDetection() {
        silenceDetectionTask?.cancel()
        silenceDetectionTask = nil
    }

    /// Stop recording and submit the audio for evaluation
    private func stopRecordingAndSubmit() async {
        cancelAutoStopRecordingTimer()
        cancelSilenceDetection()
        voiceCommandService?.setRecordingActive(false)
        isAutoRecording = false
        speechDetectedDuringAutoRecord = false

        if isStreamingSTT {
            // Streaming path: commit and let the event listener handle the response
            do {
                try await sttService?.commitAndClose()
                // The STT event listener will call handleCommittedTranscript
            } catch {
                // Cleanup and fallback
                isStreamingSTT = false
                audioService.stopStreamingRecording()
                await sttService?.disconnect()
                errorMessage = "Transcription failed: \(error.localizedDescription)"
                quizState = .askingQuestion
            }
        } else {
            // Batch path: stop M4A recording and upload
            do {
                let data = try await audioService.stopRecording()
                await submitVoiceAnswer(audioData: data)
            } catch {
                errorMessage = "Recording failed: \(error.localizedDescription)"
                quizState = .askingQuestion

                if Config.verboseLogging {
                    print("❌ Recording stop failed: \(error)")
                }
            }
        }
    }

    /// Submit a voice answer with timeout and cancellation support
    func submitVoiceAnswer(audioData: Data) async {
        guard let sessionId = currentSession?.id else {
            quizState = .error(message: "No active session", context: .general)
            return
        }

        quizState = .processing
        errorMessage = nil

        // Create a task that can be cancelled via cancelProcessing()
        voiceSubmissionTask = Task { [weak self] in
            guard let self else { return }

            do {
                if Config.verboseLogging {
                    print("🎤 Submitting voice answer: \(audioData.count) bytes")
                }

                // Race the network call against a 30-second timeout
                let response = try await withUserFacingTimeout(seconds: 30) {
                    try await self.networkService.submitVoiceAnswer(
                        sessionId: sessionId,
                        audioData: audioData,
                        fileName: "answer.m4a"
                    )
                }

                // Check for cancellation before updating UI
                try Task.checkCancellation()

                // Check if response has a valid evaluation before showing confirmation
                guard let evaluation = response.evaluation else {
                    if Config.verboseLogging {
                        print("⚠️ No evaluation in response - speech may not have been recognized")
                    }
                    // Return to error state so user can re-record
                    await MainActor.run {
                        self.quizState = .error(
                            message: "Could not understand your answer. Please speak clearly and try again.",
                            context: .submission
                        )
                    }
                    return
                }

                // Store response and show confirmation modal
                await MainActor.run {
                    self.pendingResponse = response
                    self.transcribedAnswer = evaluation.userAnswer
                    self.showAnswerConfirmation = true
                }

                // Don't call handleQuizResponse yet - wait for user confirmation

            } catch is CancellationError {
                // User cancelled - state already cleaned up by cancelProcessing()
                if Config.verboseLogging {
                    print("🚫 Voice submission task was cancelled")
                }
            } catch is TimeoutError {
                await MainActor.run {
                    self.quizState = .error(
                        message: "Request timed out. Please try again.",
                        context: .submission
                    )
                }

                if Config.verboseLogging {
                    print("⏱️ Voice submission timed out after 30 seconds")
                }
            } catch let error as NetworkError {
                // Handle "speech not understood" errors gracefully - let user re-record
                if case .serverError(let statusCode, let message) = error, statusCode == 400 {
                    await MainActor.run {
                        self.errorMessage = message
                        self.quizState = .askingQuestion  // Return to ready state for re-recording
                    }

                    if Config.verboseLogging {
                        print("⚠️ Speech not understood, returning to question: \(message)")
                    }
                    return
                }

                // Other network errors go to error screen
                await MainActor.run {
                    self.quizState = .error(
                        message: "Failed to submit answer: \(error.localizedDescription)",
                        context: .submission
                    )
                }

                if Config.verboseLogging {
                    print("❌ Error submitting answer: \(error)")
                }
            } catch {
                await MainActor.run {
                    self.quizState = .error(
                        message: "Failed to submit answer: \(error.localizedDescription)",
                        context: .submission
                    )
                }

                if Config.verboseLogging {
                    print("❌ Error submitting answer: \(error)")
                }
            }
        }

        // Wait for the task to complete
        await voiceSubmissionTask?.value
    }

    /// User-facing timeout error
    private struct TimeoutError: Error {}

    /// Runs an async operation with a timeout, throwing TimeoutError if exceeded
    private func withUserFacingTimeout<T: Sendable>(
        seconds: Int,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                throw TimeoutError()
            }

            // Return first result, cancel the other
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Confirm the transcribed answer and proceed to show result
    func confirmAnswer() async {
        showAnswerConfirmation = false

        // If we have a pending Whisper response, use it directly
        if let response = pendingResponse {
            pendingResponse = nil
            await handleQuizResponse(response)
            return
        }

        // Streaming STT path: submit the transcribed text via /sessions/{id}/input
        guard !transcribedAnswer.isEmpty else { return }
        await resubmitAnswer(transcribedAnswer)
    }

    /// Defense-in-depth cleanup if the answer confirmation sheet is dismissed
    /// without Confirm or Re-record (e.g., programmatic dismiss, future changes).
    /// No-op when pendingResponse was already consumed by confirmAnswer/rerecordAnswer.
    func handleAnswerConfirmationDismissed() {
        guard pendingResponse != nil else { return }
        pendingResponse = nil
        quizState = .askingQuestion
        errorMessage = nil
    }

    /// Reject the transcribed answer and return to ready-to-record state
    func rerecordAnswer() {
        showAnswerConfirmation = false
        pendingResponse = nil
        isRerecording = true
        quizState = .askingQuestion  // Return to ready state, not recording
        errorMessage = nil
    }

    /// Cancel the processing operation and return to question state
    func cancelProcessing() {
        voiceSubmissionTask?.cancel()
        voiceSubmissionTask = nil
        cancelAnswerTimer()
        cancelAutoStopRecordingTimer()
        cancelSilenceDetection()
        cleanupStreamingSTT()
        isAutoRecording = false
        speechDetectedDuringAutoRecord = false
        showAnswerConfirmation = false
        pendingResponse = nil
        transcribedAnswer = ""
        liveTranscript = ""
        quizState = .askingQuestion
        errorMessage = nil

        if Config.verboseLogging {
            print("🚫 Voice submission cancelled by user")
        }
    }

    /// Clean up streaming STT resources
    private func cleanupStreamingSTT() {
        sttEventTask?.cancel()
        sttEventTask = nil
        sttChunkTask?.cancel()
        sttChunkTask = nil
        if isStreamingSTT {
            audioService.stopStreamingRecording()
            Task { await sttService?.disconnect() }
            isStreamingSTT = false
            liveTranscript = ""
        }
    }

    /// Whether to retry with a new session (for initialization errors)
    var shouldRetryWithNewSession: Bool {
        if case .error(_, let context) = quizState {
            return context == .initialization
        }
        return false
    }

    /// Retry the last operation based on error context
    func retryLastOperation() async {
        guard case .error(_, let context) = quizState else { return }
        switch context {
        case .submission, .recording:
            // Return to question for re-recording or re-submission
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
            quizState = .error(
                message: "Failed to resubmit answer: \(error.localizedDescription)",
                context: .submission
            )

            if Config.verboseLogging {
                print("❌ Error resubmitting answer: \(error)")
            }
        }
    }

    /// Skip the current question
    func skipQuestion() async {
        guard let sessionId = currentSession?.id else { return }

        cancelAnswerTimer()

        // Stop any playing question audio immediately
        await stopAnyPlayingAudio()

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
            quizState = .error(
                message: "Failed to skip question: \(error.localizedDescription)",
                context: .submission
            )

            if Config.verboseLogging {
                print("❌ Error skipping question: \(error)")
            }
        }
    }

    /// End the current quiz session
    func endQuiz() async {
        guard let sessionId = currentSession?.id else { return }

        cancelAnswerTimer()
        cancelAutoStopRecordingTimer()

        do {
            try await networkService.endSession(sessionId: sessionId)
            persistenceStore.clearSession()
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
        guard persistenceStore.currentSessionId != nil else {
            errorMessage = "No saved session found"
            return
        }

        // For now, just start a new quiz
        // In a full implementation, we'd fetch the session state from backend
        await startNewQuiz()
    }

    /// Reset to home screen immediately (without network call)
    func resetToHome() {
        persistenceStore.clearSession()
        resetState()

        if Config.verboseLogging {
            print("🏠 Reset to home")
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

            // Persist preference (auto-persisted via $settings sink)
            settings.preferredInputDeviceId = device?.id

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

    // MARK: - Auto-Record or Timer

    /// Choose between auto-record (Phase 2) or answer timer (Phase 1) based on settings
    private func startRecordingOrTimer() async {
        guard quizState == .askingQuestion else { return }

        if settings.autoRecordEnabled && voiceCommandService != nil && !isRerecording {
            // Auto-record path: 500ms pause → auto-start recording
            try? await Task.sleep(nanoseconds: Config.autoRecordDelayMs * 1_000_000)
            guard quizState == .askingQuestion else { return }
            isAutoRecording = true
            await startRecording()
        } else {
            startAnswerTimer()
        }
    }

    // MARK: - Answer Timer

    /// Start countdown timer that auto-starts recording when it expires
    private func startAnswerTimer() {
        let limit = settings.answerTimeLimit
        guard limit > 0, !isRerecording else { return }

        cancelAnswerTimer()
        answerTimerCountdown = limit

        answerTimerTask = Task { [weak self] in
            guard let self else { return }

            for remaining in (0...limit).reversed() {
                if Task.isCancelled { return }

                await MainActor.run {
                    self.answerTimerCountdown = remaining
                }

                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }

            if Task.isCancelled { return }

            // Auto-start recording when timer expires
            await MainActor.run {
                guard self.quizState == .askingQuestion else { return }
                Task {
                    await self.startRecording()
                }
            }
        }
    }

    /// Cancel the answer countdown timer
    private func cancelAnswerTimer() {
        answerTimerTask?.cancel()
        answerTimerTask = nil
        answerTimerCountdown = 0
    }

    /// Start a timer that auto-stops recording after Config.autoRecordingDuration
    private func startAutoStopRecordingTimer() {
        guard !isRerecording else { return }

        cancelAutoStopRecordingTimer()

        autoStopRecordingTask = Task { [weak self] in
            guard let self else { return }

            try? await Task.sleep(nanoseconds: UInt64(Config.autoRecordingDuration * 1_000_000_000))

            if Task.isCancelled { return }

            await MainActor.run {
                guard self.quizState == .recording else { return }
                Task {
                    await self.stopRecordingAndSubmit()
                }
            }
        }
    }

    /// Cancel the auto-stop recording timer
    private func cancelAutoStopRecordingTimer() {
        autoStopRecordingTask?.cancel()
        autoStopRecordingTask = nil
    }

    private func handleQuizResponse(_ response: QuizResponse) async {
        // Guard against concurrent calls (safe: @MainActor serializes access)
        guard !isProcessingResponse else {
            if Config.verboseLogging {
                print("⚠️ handleQuizResponse already in progress, ignoring duplicate call")
            }
            return
        }
        isProcessingResponse = true
        defer { isProcessingResponse = false }

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
            quizState = .error(
                message: "Could not evaluate your answer. Please try again.",
                context: .submission
            )
            return
        }

        // Validate question ID matches between evaluation and current question
        if let evalQuestionId = evaluation.questionId,
           let currentQId = currentQuestion?.id,
           evalQuestionId != currentQId {
            print("⚠️ MISMATCH: evaluation.questionId=\(evalQuestionId) != currentQuestion.id=\(currentQId)")
        }

        // CRITICAL: Capture the current question for the result state
        // The associated value bundles question + evaluation together,
        // making it impossible to show stale/mismatched data
        guard let question = currentQuestion else {
            quizState = .error(message: "No question to evaluate", context: .general)
            return
        }

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
                try persistenceStore.addQuestionId(questionId)
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
        quizState = .showingResult(question: question, evaluation: evaluation)

        // Auto-extend session TTL to prevent timeout on long drives
        if let sessionId = currentSession?.id {
            Task {
                try? await networkService.extendSession(sessionId: sessionId, minutes: 30)
            }
        }

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
                guard self.quizState.isShowingResult else {
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
        guard quizState.isShowingResult else {
            if Config.verboseLogging {
                print("⚠️ Ignoring proceedToNextQuestion - not in showingResult state")
            }
            return
        }

        // Reset per-question pause and re-record state when moving to next question
        currentQuestionPaused = false
        isRerecording = false

        // CRITICAL: Stop any playing feedback audio before transitioning
        // This ensures clean state transition from ResultView to QuestionView
        await stopAnyPlayingAudio()

        // Small delay to ensure audio cleanup completes
        try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1 seconds

        // Determine next state based on session status
        if let session = currentSession, session.isFinished {
            // Quiz is complete
            quizState = .finished
            persistenceStore.clearSession()

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
            } else {
                // No audio — auto-record or timer based on settings
                await startRecordingOrTimer()
            }

            if Config.verboseLogging {
                print("❓ Showing next question: \(currentQuestion?.question ?? "unknown")")
            }
        }
    }

    private func playQuestionAudio(from urlString: String) async {
        // Store URL for "repeat" command
        currentQuestionAudioUrl = urlString

        // Set echo cancellation text and TTS active flag before playback
        voiceCommandService?.setPlaybackText(currentQuestion?.question)
        voiceCommandService?.setTTSPlaybackActive(true)

        do {
            let audioData = try await networkService.downloadAudio(from: urlString)
            _ = try await audioService.playOpusAudio(audioData)
        } catch {
            if Config.verboseLogging {
                print("⚠️ Failed to play question audio: \(error)")
            }
            // Don't fail the quiz if audio doesn't play
        }

        // Clear echo cancellation and TTS active flag after playback
        voiceCommandService?.setPlaybackText(nil)
        voiceCommandService?.setTTSPlaybackActive(false)

        // After TTS finishes (or was interrupted by barge-in), choose next path
        guard quizState == .askingQuestion else { return }

        if settings.autoRecordEnabled && voiceCommandService != nil && !isRerecording {
            // Auto-record path: 500ms pause → auto-start recording
            try? await Task.sleep(nanoseconds: Config.autoRecordDelayMs * 1_000_000)
            guard quizState == .askingQuestion else { return }
            isAutoRecording = true
            await startRecording()
        } else {
            // Legacy path: countdown timer → fixed duration recording
            startAnswerTimer()
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
        // Cancel any pending tasks
        autoAdvanceTask?.cancel()
        autoAdvanceTask = nil
        voiceSubmissionTask?.cancel()
        voiceSubmissionTask = nil
        answerTimerTask?.cancel()
        answerTimerTask = nil
        autoStopRecordingTask?.cancel()
        autoStopRecordingTask = nil
        silenceDetectionTask?.cancel()
        silenceDetectionTask = nil
        sttEventTask?.cancel()
        sttEventTask = nil
        sttChunkTask?.cancel()
        sttChunkTask = nil
        bargeInTask?.cancel()
        bargeInTask = nil

        // Clean up streaming STT
        cleanupStreamingSTT()

        // Stop voice commands
        stopVoiceCommands()

        // Stop any playing audio
        Task {
            await stopAnyPlayingAudio()
        }

        // Reset all state
        isProcessingResponse = false
        quizState = .idle
        currentQuestion = nil
        currentSession = nil
        score = 0.0
        questionsAnswered = 0
        errorMessage = nil
        nextQuestionAudioUrl = nil
        nextQuestion = nil
        currentQuestionAudioUrl = nil
        autoAdvanceCountdown = 0
        answerTimerCountdown = 0
        currentQuestionPaused = false
        autoAdvanceEnabled = true
        isRerecording = false
        isAutoRecording = false
        speechDetectedDuringAutoRecord = false
        isStreamingSTT = false
        liveTranscript = ""
        pendingResponse = nil
        transcribedAnswer = ""
        showAnswerConfirmation = false
    }

    // MARK: - Voice Commands

    /// Start listening for voice commands and subscribe to the command stream
    private func startVoiceCommands() {
        guard let service = voiceCommandService, settings.voiceCommandsEnabled else {
            voiceCommandState = .disabled
            return
        }

        voiceCommandTask = Task { [weak self] in
            await service.startListening()

            for await command in service.commands {
                guard let self, !Task.isCancelled else { break }
                await self.handleVoiceCommand(command)
            }
        }

        // Subscribe to barge-in events (speech during TTS on external audio)
        if settings.bargeInEnabled {
            bargeInTask = Task { [weak self] in
                for await _ in service.bargeInEvents {
                    guard let self, !Task.isCancelled else { break }
                    await self.handleBargeIn()
                }
            }
        }

        // Sync UI state
        voiceCommandState = .listening
    }

    /// Stop voice command listening
    private func stopVoiceCommands() {
        voiceCommandTask?.cancel()
        voiceCommandTask = nil
        bargeInTask?.cancel()
        bargeInTask = nil
        voiceCommandService?.stopListening()
        voiceCommandState = .disabled
    }

    /// Handle barge-in: user spoke during TTS playback on external audio route
    private func handleBargeIn() async {
        // Only barge-in during question playback
        guard quizState == .askingQuestion else { return }

        if Config.verboseLogging {
            print("🗣️ Barge-in triggered — stopping TTS and starting recording")
        }

        // 1. Stop TTS immediately
        await stopAnyPlayingAudio()

        // 2. Clear echo cancellation state
        voiceCommandService?.setPlaybackText(nil)
        voiceCommandService?.setTTSPlaybackActive(false)

        // 3. Wait for audio hardware to settle
        try? await Task.sleep(nanoseconds: 500_000_000) // 500ms

        // 4. Guard again — state may have changed during sleep
        guard quizState == .askingQuestion else { return }

        // 5. Auto-start recording (same as post-TTS flow)
        cancelAnswerTimer()
        isAutoRecording = true
        await startRecording()
    }

    /// Dispatch a voice command to the appropriate action based on current state
    private func handleVoiceCommand(_ command: VoiceCommand) async {
        // Update UI state briefly
        voiceCommandState = .commandDetected(command)

        switch command {
        case .start:
            if quizState == .askingQuestion {
                cancelAnswerTimer()
                await startRecording()
            } else if showAnswerConfirmation {
                rerecordAnswer()
            }

        case .stop:
            if quizState == .recording {
                cancelAutoStopRecordingTimer()
                await stopRecordingAndSubmit()
            }

        case .skip:
            if quizState == .askingQuestion {
                await skipQuestion()
            }

        case .repeat:
            if quizState == .askingQuestion, let audioUrl = currentQuestionAudioUrl {
                cancelAnswerTimer()
                await stopAnyPlayingAudio()
                await playQuestionAudio(from: audioUrl)
            }

        case .score:
            if quizState == .askingQuestion || quizState.isShowingResult {
                let total = currentSession?.maxQuestions ?? 0
                let current = questionsAnswered + (quizState == .askingQuestion ? 1 : 0)
                let text = "Your score is \(Int(score)) out of \(questionsAnswered). Question \(current) of \(total)."
                await audioService.speakText(text)
            }

        case .help:
            if quizState == .askingQuestion {
                let text = "Say skip to skip, start to record, stop to submit, or ok to confirm."
                await audioService.speakText(text)
            }

        case .ok:
            if showAnswerConfirmation && !isProcessingResponse {
                await confirmAnswer()
            }
        }

        // Reset to listening after brief delay
        try? await Task.sleep(nanoseconds: 300_000_000)
        if voiceCommandTask != nil {
            voiceCommandState = .listening
        }
    }

    // MARK: - Question History Management

    /// Number of questions in history
    var questionHistoryCount: Int {
        persistenceStore.askedQuestionIds.count
    }

    /// Reset question history (allows previously seen questions to appear again)
    func resetQuestionHistory() {
        persistenceStore.clearHistory()

        if Config.verboseLogging {
            print("🗑️ Question history reset by user")
        }
    }

    /// Whether voice commands are available (service exists and setting enabled)
    var voiceCommandsAvailable: Bool {
        voiceCommandService != nil
    }
}

// MARK: - Preview Helpers

#if DEBUG
extension QuizViewModel {
    static let preview: QuizViewModel = {
        let viewModel = QuizViewModel(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
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
            persistenceStore: MockPersistenceStore()
        )
        viewModel.currentQuestion = Question.preview
        viewModel.score = 1.0
        viewModel.questionsAnswered = 1
        viewModel.quizState = .showingResult(
            question: Question.preview,
            evaluation: Evaluation.previewCorrect
        )
        viewModel.settings.audioMode = AudioMode.default.id
        return viewModel
    }()
}
#endif
