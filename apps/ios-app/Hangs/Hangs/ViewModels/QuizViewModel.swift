//
//  QuizViewModel.swift
//  Hangs
//
//  Core quiz flow and state management
//

import Foundation
import Combine
import os
import Sentry

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

    /// Short label for logging (no associated values)
    var label: String {
        switch self {
        case .idle: return "idle"
        case .startingQuiz: return "startingQuiz"
        case .askingQuestion: return "askingQuestion"
        case .recording: return "recording"
        case .processing: return "processing"
        case .showingResult: return "showingResult"
        case .finished: return "finished"
        case .error: return "error"
        }
    }

    /// Valid successor states for state machine validation.
    /// Every state includes "idle" as a valid transition to support resetState()/resetToHome()
    /// being called from any phase. "processing" is added to showingResult for resubmitAnswer().
    var validTransitions: Set<String> {
        switch self {
        case .idle: return ["startingQuiz"]
        case .startingQuiz: return ["askingQuestion", "error", "idle"]
        case .askingQuestion: return ["recording", "processing", "error", "idle"]
        case .recording: return ["processing", "askingQuestion", "error", "idle"]
        case .processing: return ["showingResult", "askingQuestion", "error", "idle"]
        case .showingResult: return ["askingQuestion", "processing", "finished", "idle"]
        case .finished: return ["idle"]
        case .error: return ["idle", "askingQuestion"]
        }
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

    #if DEBUG
    /// Rich debug dump of the most recent error — type, localizedDescription, `String(reflecting:)`,
    /// and underlying NSError chain. Consumed by `DebugErrorDetailsView`. Populated alongside
    /// `setError(message:context:)` at catch sites that surface a caught `Error`.
    @Published var lastErrorDebugInfo: String?
    #endif

    // Paywall state
    @Published var showPaywall: Bool = false
    @Published var dailyLimitError: DailyLimitError?
    @Published var usageInfo: UsageInfo?

    // Answer confirmation modal state
    @Published var showAnswerConfirmation = false
    @Published var transcribedAnswer = ""
    @Published var autoConfirmCountdown: Int = 0
    var pendingResponse: QuizResponse? = nil  // internal for QuizViewModel+Recording
    var transcriptWasEdited = false  // internal — suppress TTS on edited confirmations
    var preEditTranscript: String? = nil  // internal — snapshot for cancelEditingTranscript()

    // Auto-advance countdown for ResultView binding (single source of truth)
    @Published var autoAdvanceCountdown: Int = 0

    // Answer timer countdown (visible on QuestionView)
    @Published var answerTimerCountdown: Int = 0

    // Thinking time countdown (visible on QuestionView before auto-recording)
    @Published var thinkingTimeCountdown: Int = 0

    // Auto-advance enabled state (global setting toggle)
    @Published var autoAdvanceEnabled: Bool = true

    // Per-question pause state (resets on next question)
    @Published var currentQuestionPaused: Bool = false

    // Minimize state
    @Published var isMinimized: Bool = false

    // MARK: - Quiz Stats

    @Published var quizStats: QuizStats = .empty

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

    // MARK: - State Machine

    /// Validated state transition with logging.
    /// Rejects invalid transitions and keeps current state — "crash-correct over crash-safe".
    /// A rejected transition is logged as an error and is a signal of a bug in the call site.
    /// Returns false if the transition was rejected; true if applied.
    @discardableResult
    func transition(to newState: QuizState, caller: String = #function) -> Bool {  // internal for extensions
        let from = quizState.label
        let to = newState.label

        guard quizState.validTransitions.contains(to) else {
            Logger.quiz.error("❌ REJECTED transition: \(from) → \(to) [\(caller, privacy: .public)]")
            return false
        }

        Logger.quiz.info("State: \(from) → \(to) [\(caller, privacy: .public)]")
        quizState = newState

        // Sentry: tag + context + breadcrumb (metadata only — no transcripts/PII)
        let questionId = currentQuestion?.id
        let questionCategory = currentQuestion?.category
        let answered = questionsAnswered
        if SentrySDK.isEnabled {
            SentrySDK.configureScope { scope in
                scope.setTag(value: to, key: "quiz.state")
                if let qid = questionId {
                    var ctx: [String: Any] = [
                        "questionId": qid,
                        "index": answered
                    ]
                    if let cat = questionCategory { ctx["category"] = cat }
                    scope.setContext(value: ctx, key: "quiz.current")
                }
            }
        }
        let crumb = Breadcrumb(level: .info, category: "quiz.transition")
        crumb.message = "\(from) → \(to) (caller: \(caller))"
        SentryBreadcrumb.add(crumb)

        return true
    }

    // MARK: - Re-entrancy Guards

    /// Simple Bool flag to prevent concurrent handleQuizResponse calls.
    /// Safe because this class is @MainActor — all access is serialized on the main thread.
    var isProcessingResponse = false

    /// Prevents concurrent stopRecordingAndSubmit calls (silence detection + user tap can race)
    var isStoppingRecording = false  // internal for QuizViewModel+Recording

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

    let networkService: NetworkServiceProtocol
    let audioService: AudioServiceProtocol
    let persistenceStore: PersistenceStoreProtocol
    let silenceDetectionService: SilenceDetectionServiceProtocol?
    let sttService: ElevenLabsSTTServiceProtocol?

    private var cancellables = Set<AnyCancellable>()

    /// Single owner for every long-lived `Task` this view model spawns.
    /// Each call site stores its task under a `TaskKey`; `resetState()` calls
    /// `cancelAll()` instead of duplicating ten cancel-and-nil lines.
    let taskBag = TaskBag()  // internal for QuizViewModel+Timers/+Recording/+Audio

    // Whether the current recording is a re-record (bypasses all timers) (internal for QuizViewModel+Timers)
    var isRerecording: Bool = false

    // Consecutive transcription failures for 3-tier error escalation
    var consecutiveTranscriptionFailures: Int = 0  // internal for QuizViewModel+Recording

    // Next question data (from response, displayed after showing results)
    private var nextQuestionAudioUrl: String?
    private var nextQuestion: Question?

    // Current question audio URL for "repeat" command
    var currentQuestionAudioUrl: String?  // internal for QuizViewModel+Audio

    // MARK: - Initialization

    init(
        networkService: NetworkServiceProtocol,
        audioService: AudioServiceProtocol,
        persistenceStore: PersistenceStoreProtocol,
        silenceDetectionService: SilenceDetectionServiceProtocol? = nil,
        sttService: ElevenLabsSTTServiceProtocol? = nil
    ) {
        self.networkService = networkService
        self.audioService = audioService
        self.persistenceStore = persistenceStore
        self.silenceDetectionService = silenceDetectionService
        self.sttService = sttService

        // Load saved settings and stats
        self.settings = persistenceStore.loadSettings()
        self.quizStats = persistenceStore.loadStats()

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
        transition(to: .startingQuiz)
        errorMessage = nil
        #if DEBUG
        lastErrorDebugInfo = nil
        #endif
        autoAdvanceEnabled = true  // Reset auto-advance for new quiz
        isRerecording = false
        consecutiveTranscriptionFailures = 0

        // Use provided parameters or fall back to settings
        let quizMaxQuestions = maxQuestions ?? settings.numberOfQuestions
        let quizDifficulty = difficulty ?? settings.difficulty
        let quizLanguage = language ?? settings.language

        // Check if question history is at capacity
        if persistenceStore.isAtCapacity {
            setError(
                message: "Question history is full. Please reset your history in Settings to continue.",
                context: .initialization
            )
            return
        }

        do {
            Logger.quiz.info("🎮 Starting new quiz: \(quizMaxQuestions, privacy: .public) questions, difficulty: \(quizDifficulty, privacy: .public), language: \(quizLanguage, privacy: .public)")

            // Get excluded question IDs from history
            let excludedIds = persistenceStore.getExclusionList()

            Logger.quiz.debug("🎮 Excluding \(excludedIds.count, privacy: .public) previously seen questions")

            // Configure audio session with user's preferred mode
            do {
                try audioService.setupAudioSession(mode: selectedAudioMode)

                Logger.audio.info("🎤 Audio session configured with \(self.selectedAudioMode.name, privacy: .public)")
            } catch {
                // Log error but continue - audio might still work
                Logger.audio.warning("⚠️ Failed to configure audio session: \(error, privacy: .public)")
            }

            // Create session with device ID for usage tracking
            let session = try await networkService.createSession(
                maxQuestions: quizMaxQuestions,
                difficulty: quizDifficulty,
                language: quizLanguage,
                category: settings.category,
                userId: persistenceStore.deviceId
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
            transition(to: .askingQuestion)

            // Save question ID to history
            if let questionId = response.currentQuestion?.id {
                do {
                    try persistenceStore.addQuestionId(questionId)
                } catch QuestionHistoryError.capacityReached {
                    // Should not happen (checked before quiz start)
                    Logger.quiz.warning("⚠️ Question history reached capacity mid-quiz")
                } catch {
                    Logger.quiz.warning("⚠️ Failed to save question to history: \(error, privacy: .public)")
                }
            }

            // Play question audio if available
            // (silence detection starts inside playQuestionAudio, after TTS finishes,
            //  to avoid AVAudioEngine + AVPlayer conflict that crashes SpeechAnalyzer)
            if let audioInfo = response.audio,
               let questionUrl = audioInfo.questionUrl {
                await playQuestionAudio(from: questionUrl)
            } else {
                // No audio — start silence detection then recording/timer
                await startSilenceDetectionListening()
                startRecordingOrTimer()
            }

        } catch let error as NetworkError {
            if case .dailyLimitReached(let limitError) = error {
                dailyLimitError = limitError
                showPaywall = true
                transition(to: .idle)
            } else {
                setError(
                    message: "Failed to start quiz: \(error.localizedDescription)",
                    context: .initialization,
                    error: error
                )
            }

            Logger.quiz.error("❌ Error starting quiz: \(error, privacy: .public)")
        } catch {
            setError(
                message: "Failed to start quiz: \(error.localizedDescription)",
                context: .initialization,
                error: error
            )

            Logger.quiz.error("❌ Error starting quiz: \(error, privacy: .public)")
        }
    }


    /// Set error state. Errors are surfaced visually via `errorMessage`
    /// and the `.error` state — we deliberately do not speak them aloud.
    /// `error` is optional; when present it is formatted into `lastErrorDebugInfo` (DEBUG only)
    /// so `DebugErrorDetailsView` can show the full chain without parsing log files.
    func setError(message: String, context: ErrorContext, error: Error? = nil) {  // internal for QuizViewModel+Recording
        #if DEBUG
        lastErrorDebugInfo = error.map { Self.formatDebugError($0, displayMessage: message) }
        #endif
        transition(to: .error(message: message, context: context))
    }

    /// Handle an error, detecting 429 daily limit and showing paywall instead of error state
    private func handleError(_ error: Error, context: ErrorContext, fallbackMessage: String) {
        if let networkError = error as? NetworkError,
           case .dailyLimitReached(let limitError) = networkError {
            dailyLimitError = limitError
            showPaywall = true
            transition(to: .idle)
        } else {
            setError(message: "\(fallbackMessage): \(error.localizedDescription)", context: context, error: error)
        }
    }

    #if DEBUG
    /// Render an Error into a multi-line block: display message, type, localized description,
    /// `String(reflecting:)` (exposes enum associated values like `NetworkError.serverError(statusCode:message:)`),
    /// and NSError domain/code/userInfo walk. Safe to call off the main actor.
    nonisolated static func formatDebugError(_ error: Error, displayMessage: String) -> String {
        var lines: [String] = []
        lines.append("Display: \(displayMessage)")
        lines.append("")
        lines.append("Type: \(type(of: error))")
        lines.append("Localized: \(error.localizedDescription)")
        lines.append("Reflecting: \(String(reflecting: error))")

        var current: NSError? = error as NSError
        var depth = 0
        while let ns = current, depth < 5 {
            lines.append("")
            lines.append("NSError[\(depth)] domain=\(ns.domain) code=\(ns.code)")
            if !ns.userInfo.isEmpty {
                for (k, v) in ns.userInfo {
                    lines.append("  \(k): \(String(describing: v))")
                }
            }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return lines.joined(separator: "\n")
    }
    #endif

    /// Fetch current usage info from backend (for displaying remaining questions)
    func refreshUsage() async {
        let userId = persistenceStore.deviceId
        do {
            usageInfo = try await networkService.getUsage(userId: userId)
        } catch {
            Logger.network.warning("⚠️ Failed to fetch usage info: \(error, privacy: .public)")
        }
    }

    /// Notify backend that this device purchased premium
    func notifyPremiumPurchased() async {
        do {
            try await networkService.setPremium(userId: persistenceStore.deviceId)
            await refreshUsage()
        } catch {
            Logger.network.warning("⚠️ Failed to notify backend of premium purchase: \(error, privacy: .public)")
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
            transition(to: .askingQuestion)
            errorMessage = nil
        default:
            // Fallback to starting new quiz
            await startNewQuiz()
        }
    }

    /// Rate the current question (1-5 stars)
    func rateQuestion(_ rating: Int) {
        guard let sessionId = currentSession?.id else { return }
        Task {
            try? await networkService.rateQuestion(sessionId: sessionId, rating: rating)
        }
    }

    /// Flag the current question as potentially incorrect
    func flagQuestion(reason: String? = nil) {
        guard let sessionId = currentSession?.id else { return }
        Task {
            try? await networkService.flagQuestion(sessionId: sessionId, reason: reason)
        }
    }

    /// Submit a multiple-choice answer directly (bypasses confirmation modal)
    ///
    /// Sends the answer **value** (e.g., "Paris") via the text input endpoint.
    /// The backend MCQ fast-path matches both keys and values, so this works
    /// regardless of whether the evaluator checks by key or value.
    func submitMCQAnswer(key: String, value: String) async {
        guard let sessionId = currentSession?.id else {
            errorMessage = "No active session"
            return
        }

        cancelAnswerTimer()
        cancelAutoStopRecordingTimer()
        transition(to: .processing)
        errorMessage = nil

        do {
            let response = try await networkService.submitTextInput(
                sessionId: sessionId,
                input: value,
                audio: settings.audioMode != "off"
            )
            await handleQuizResponse(response)
        } catch {
            handleError(error, context: .submission, fallbackMessage: "Failed to submit answer")
        }
    }

    /// Resubmit an edited text answer
    func resubmitAnswer(_ newAnswer: String, suppressAudio: Bool = false) async {
        guard let sessionId = currentSession?.id else {
            errorMessage = "No active session"
            return
        }

        // Stop any in-flight voice machinery so the typed answer wins the race
        // against a silent auto-stop submission. Answer/thinking timers are left
        // running on purpose — they no-op once state ≠ .askingQuestion.
        taskBag.cancel(.voiceSubmission)
        cancelAutoStopRecordingTimer()
        cancelSilenceDetection()
        if quizState == .recording {
            isAutoRecording = false
            speechDetectedDuringAutoRecord = false
            if isStreamingSTT {
                cleanupStreamingSTT()
            } else {
                _ = try? await audioService.stopRecording()
            }
        }

        // The confirmation modal already moved us to .processing in
        // handleCommittedTranscript; only transition when called from a
        // pre-modal state (e.g., still .recording on the batch path).
        if quizState != .processing {
            transition(to: .processing)
        }
        errorMessage = nil

        do {
            Logger.network.info("✏️ Resubmitting edited answer: \(newAnswer, privacy: .public)")

            let response = try await networkService.submitTextInput(
                sessionId: sessionId,
                input: newAnswer,
                audio: !suppressAudio && settings.audioMode != "off"
            )

            await handleQuizResponse(response)

        } catch {
            handleError(error, context: .submission, fallbackMessage: "Failed to resubmit answer")

            Logger.network.error("❌ Error resubmitting answer: \(error, privacy: .public)")
        }
    }

    /// Skip the current question
    func skipQuestion() async {
        guard let sessionId = currentSession?.id else { return }

        cancelAnswerTimer()
        cancelThinkingTime()

        // Stop any playing question audio immediately
        await stopAnyPlayingAudio()

        transition(to: .processing)
        errorMessage = nil

        do {
            Logger.quiz.info("⏭️ Skipping current question")

            let response = try await networkService.submitTextInput(
                sessionId: sessionId,
                input: "skip",
                audio: settings.audioMode != "off"
            )

            await handleQuizResponse(response)
        } catch {
            handleError(error, context: .submission, fallbackMessage: "Failed to skip question")

            Logger.quiz.error("❌ Error skipping question: \(error, privacy: .public)")
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
            await stopAnyPlayingAudio()  // Await properly (we're async here)
            resetState()

            Logger.quiz.info("🎮 Quiz ended")
        } catch {
            errorMessage = "Failed to end quiz: \(error.localizedDescription)"

            Logger.quiz.error("❌ Error ending quiz: \(error, privacy: .public)")
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
        // Fire-and-forget is acceptable here: UI transition is immediate,
        // brief audio overlap is non-critical. Task is tracked via audioService state.
        Task {
            await audioService.stopPlayback()
        }

        Logger.quiz.info("🏠 Reset to home")
    }

    /// Pause auto-advance for current question only (not permanent)
    func pauseQuiz() {
        taskBag.cancel(.autoAdvance)
        currentQuestionPaused = true

        Logger.quiz.info("⏸️ Current question paused - auto-advance will resume on next question")
    }

    /// Continue to next question after user paused current one
    func continueToNext() {
        // Reset per-question pause state
        currentQuestionPaused = false

        Task {
            await proceedToNextQuestion()
        }

        Logger.quiz.info("▶️ Continuing to next question - auto-advance re-enabled")
    }

    /// Resume the quiz (proceeds to next question immediately, no auto-advance)
    func resumeQuiz() {
        Task {
            await proceedToNextQuestion()
        }

        Logger.quiz.info("▶️ Quiz resumed - proceeding to next question")
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

    // MARK: - Auto-Record or Timer

    /// Choose between auto-record (Phase 2) or answer timer (Phase 1) based on settings
    private func startRecordingOrTimer() {
        guard quizState == .askingQuestion else { return }
        guard currentQuestion?.isMultipleChoice != true else { return }

        if settings.autoRecordEnabled && silenceDetectionService != nil && !isRerecording {
            // Auto-record path: thinking time countdown → auto-start recording
            startThinkingTimeCountdown()
        } else {
            startAnswerTimer()
        }
    }

    func handleQuizResponse(_ response: QuizResponse) async {  // internal for QuizViewModel+Recording
        // Guard against concurrent calls (safe: @MainActor serializes access)
        guard !isProcessingResponse else {
            Logger.quiz.warning("⚠️ handleQuizResponse already in progress, ignoring duplicate call")
            return
        }
        isProcessingResponse = true
        defer { isProcessingResponse = false }

        // Reset transcription failure counter on successful response
        consecutiveTranscriptionFailures = 0

        // Cancel any previous auto-advance task
        taskBag.cancel(.autoAdvance)

        // Update session state
        currentSession = response.session

        // CRITICAL: Validate evaluation exists before showing result
        guard let evaluation = response.evaluation else {
            Logger.quiz.error("❌ No evaluation in response, cannot show result")
            setError(
                message: "Could not evaluate your answer. Please try again.",
                context: .submission
            )
            return
        }

        // Validate question ID matches between evaluation and current question
        if let evalQuestionId = evaluation.questionId,
           let currentQId = currentQuestion?.id,
           evalQuestionId != currentQId {
            Logger.quiz.warning("⚠️ MISMATCH: evaluation.questionId=\(evalQuestionId, privacy: .public) != currentQuestion.id=\(currentQId, privacy: .public)")
        }

        // CRITICAL: Capture the current question for the result state
        // The associated value bundles question + evaluation together,
        // making it impossible to show stale/mismatched data
        guard let question = currentQuestion else {
            setError(message: "No question to evaluate", context: .general)
            return
        }

        // Update score and question count
        if let participant = response.session.participants.first {
            score = participant.score
            questionsAnswered = participant.answeredCount
        }

        // Update quiz stats (streak tracking)
        if evaluation.result != .skipped {
            quizStats.recordAnswer(isCorrect: evaluation.isCorrect)
            persistenceStore.saveStats(quizStats)
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
                Logger.quiz.warning("⚠️ Question history reached capacity mid-quiz")
            } catch {
                Logger.quiz.warning("⚠️ Failed to save question to history: \(error, privacy: .public)")
            }
        }

        // IMPORTANT: Show result screen BEFORE playing audio
        // This ensures ResultView is visible when audio starts playing
        transition(to: .showingResult(question: question, evaluation: evaluation))

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

    /// Proceed to next question or finish quiz
    /// Can be called manually via button or automatically via timer
    func proceedToNextQuestion() async {
        // Cancel any pending auto-advance
        taskBag.cancel(.autoAdvance)

        // Only proceed if currently showing results
        guard quizState.isShowingResult else {
            Logger.quiz.warning("⚠️ Ignoring proceedToNextQuestion - not in showingResult state")
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
            // Quiz is complete — record stats
            quizStats.recordQuizCompleted()
            persistenceStore.saveStats(quizStats)
            transition(to: .finished)
            persistenceStore.clearSession()

            Logger.quiz.info("🎮 Quiz finished! Final score: \(self.score, privacy: .public)")
        } else {
            // More questions remain - NOW update currentQuestion with stored next question
            // This ensures the next question only appears AFTER showing results
            currentQuestion = nextQuestion
            nextQuestion = nil  // Clear after use

            // Transition to asking question state
            transition(to: .askingQuestion)

            // Play next question audio if available
            if let questionUrl = nextQuestionAudioUrl {
                await playQuestionAudio(from: questionUrl)
                nextQuestionAudioUrl = nil  // Clear after use
            } else {
                // No audio — auto-record or timer based on settings
                startRecordingOrTimer()
            }

            Logger.quiz.info("❓ Showing next question: \(self.currentQuestion?.question ?? "unknown", privacy: .public)")
        }
    }

    /// Repeat the current question audio (public for UI button)
    func repeatQuestion() async {
        if quizState == .askingQuestion, let audioUrl = currentQuestionAudioUrl {
            cancelAnswerTimer()
            cancelThinkingTime()
            await stopAnyPlayingAudio()
            await playQuestionAudio(from: audioUrl)
        }
    }

    private func resetState() {
        // Cancel every long-lived background task in one call.
        taskBag.cancelAll()

        // Clean up streaming STT
        cleanupStreamingSTT()

        // Stop silence detection / barge-in listening
        stopSilenceDetectionListening()

        // Reset all state
        // Note: audio stop must be awaited by async callers (endQuiz) before resetState().
        // resetToHome() fires an untracked Task separately — brief audio overlap is acceptable.
        isProcessingResponse = false
        transition(to: .idle)
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
        thinkingTimeCountdown = 0
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

    // MARK: - Question History Management

    /// Number of questions in history
    var questionHistoryCount: Int {
        persistenceStore.askedQuestionIds.count
    }

    /// Reset question history (allows previously seen questions to appear again)
    func resetQuestionHistory() {
        persistenceStore.clearHistory()

        Logger.persistence.info("🗑️ Question history reset by user")
    }

    /// Whether on-device silence detection / auto-record is available (iOS 26+).
    var silenceDetectionAvailable: Bool {
        silenceDetectionService != nil
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
