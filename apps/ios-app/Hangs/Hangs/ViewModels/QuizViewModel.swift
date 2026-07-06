//
//  QuizViewModel.swift
//  Hangs
//
//  Core quiz flow and state management
//

import Combine
import Foundation
import os
import Sentry

/// Error context for distinguishing error types
enum ErrorContext: Sendable {
    case initialization // Error during session creation or quiz start
    case submission // Error during answer submission
    case recording // Error during audio recording
    case general // Other errors
}

/// Quiz state machine
enum QuizState: Sendable {
    case idle
    case startingQuiz
    case askingQuestion
    case recording
    case processing
    case skipping
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
             (.skipping, .skipping),
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
        case .skipping: return "skipping"
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
        case .askingQuestion: return ["recording", "processing", "skipping", "error", "idle"]
        case .recording: return ["processing", "skipping", "askingQuestion", "error", "idle"]
        case .processing: return ["showingResult", "skipping", "askingQuestion", "error", "idle"]
        case .skipping: return ["showingResult", "askingQuestion", "error", "idle"]
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

    // Per-session evaluation tallies for the completion breakdown (54.13) —
    // partials and skips land in neither bucket.
    @Published var sessionCorrectCount: Int = 0
    @Published var sessionIncorrectCount: Int = 0
    @Published var errorMessage: String? // Inline errors shown in QuestionView (e.g., recording failures)
    /// Display model for the full-screen Error state, built by `setError` via
    /// `AppErrorModel.from` so ErrorView shows localised copy + the right CTA (54.15).
    @Published private(set) var activeErrorModel: AppErrorModel?

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
    var pendingResponse: QuizResponse? = nil // internal for QuizViewModel+Recording
    var transcriptWasEdited = false // internal — suppress TTS on edited confirmations
    var preEditTranscript: String? = nil // internal — snapshot for cancelEditingTranscript()

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

    // True while a modal (End-Quiz dialog, in-quiz settings sheet) covers the quiz
    // screen. The thinking/answer countdowns freeze while set (#81) — the user
    // must not be timed while the app itself has taken over the screen. Set by
    // the presenting views; deliberately NOT part of QuizState (same separate-axis
    // pattern as commandCapturePhase).
    @Published var isQuizModalPresented: Bool = false

    // Minimize state
    @Published var isMinimized: Bool = false

    // MARK: - Command Capture Phase (#77, task 77.4)

    /// Additive capture-phase observable (E-state) — the single source of truth
    /// for earcons (77.10) and the deferred recording UI (P5). SEPARATE axis from
    /// `quizState`; driven off injected audio-lifecycle events via
    /// `applyCaptureEvent(_:)`. Deliberately NOT part of QuizState/validTransitions.
    @Published private(set) var commandCapturePhase: CommandCapturePhase = .idle

    /// Observation hook / test seam (#77, task 77.5): invoked when the command
    /// listener recognizes a screen-scoped command, BEFORE it is routed to an
    /// action. Session 3 fired it as the only behaviour; Session 4 (77.8–77.9) adds
    /// the routing in `handleRecognizedCommand`. Kept for tests + future earcons.
    var onCommandRecognized: (@MainActor (VoiceCommand) -> Void)?

    // MARK: - Voice Command Wiring (#77, tasks 77.8 / 77.9)

    /// P4a founder-overridable flag: spoken "start" on QuestionView opens the mic.
    /// Seeded from `Config.voiceStartCommandEnabled` (default ON); an instance
    /// property so tests can flip it and a future settings UI can bind it. `false`
    /// disables ONLY the question-screen "start"→`startRecording()` wiring — the
    /// rest of the command layer (and Home "start") stays intact.
    var voiceStartOnQuestionEnabled: Bool = Config.voiceStartCommandEnabled

    /// Founder-overridable flag: arm the command listener on the idle Home screen so
    /// spoken "start" begins the quiz. Seeded from `Config.voiceHomeStartEnabled`
    /// (default ON). Consulted by `HomeView.onAppear` before arming.
    var voiceStartOnHomeEnabled: Bool = Config.voiceHomeStartEnabled

    /// Skip undo-window (#77, task 77.9 / E-match): a recognized "skip" on the
    /// question screen opens a ~2.5 s window before the skip commits, so a tap (or,
    /// deferred to Session 5, a spoken cancel word) can abort it. `nil` = no pending
    /// skip. Published so the deferred UI + earcons can observe it.
    @Published private(set) var pendingSkipWindow: UndoWindow?

    /// Session 5 earcon seam (77.10): fired when the skip undo-window OPENS. The
    /// skip-confirm earcon itself is Session 5 — Session 4 only exposes the event.
    var onSkipUndoWindowOpened: (@MainActor () -> Void)?

    /// Apply an injected capture-lifecycle event. Illegal transitions are a no-op
    /// (phase unchanged) and return `false` so a caller can detect a bad sequence.
    @discardableResult
    func applyCaptureEvent(_ event: CaptureLifecycleEvent) -> Bool {
        guard let next = commandCapturePhase.applying(event) else { return false }
        commandCapturePhase = next
        return true
    }

    /// Single funnel for every earcon (77.10). Suppresses cues during question
    /// TTS (`isPlayingQuestionTTS`) so a tone never plays over the spoken
    /// question — the one hard rule for the language-neutral cue set.
    func emitEarcon(_ earcon: Earcon) {
        guard !isPlayingQuestionTTS else { return }
        earconPlayer.play(earcon)
    }

    // MARK: - Quiz Stats

    @Published var quizStats: QuizStats = .empty

    /// Streak value immediately before the last recorded answer — captured because
    /// `quizStats.currentStreak` is already 0 by the time ResultView renders an
    /// incorrect answer (54.11).
    @Published var streakBeforeLastAnswer: Int = 0

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
        return String(localized: "Automatic", comment: "Fallback name when no audio input device is selected (iOS picks the best mic)")
    }

    /// Sheet presentation state for microphone picker
    @Published var showingMicrophonePicker = false

    /// Whether minimize is allowed in current state
    /// Enabled during active quiz states (question, recording, processing, results)
    var canMinimize: Bool {
        switch quizState {
        case .askingQuestion, .recording, .processing, .skipping, .showingResult:
            return true
        default:
            return false
        }
    }

    // MARK: - Result Accessors (extract associated values for Views)

    /// The question being displayed on the result screen
    var resultQuestion: Question? {
        if case let .showingResult(question, _) = quizState { return question }
        return nil
    }

    /// The evaluation being displayed on the result screen
    var resultEvaluation: Evaluation? {
        if case let .showingResult(_, evaluation) = quizState { return evaluation }
        return nil
    }

    // MARK: - State Machine

    /// Validated state transition with logging.
    /// Rejects invalid transitions and keeps current state — "crash-correct over crash-safe".
    /// A rejected transition is logged as an error and is a signal of a bug in the call site.
    /// Returns false if the transition was rejected; true if applied.
    @discardableResult
    func transition(to newState: QuizState, caller: String = #function) -> Bool { // internal for extensions
        let from = quizState.label
        let to = newState.label

        guard quizState.validTransitions.contains(to) else {
            Logger.quiz.error("❌ REJECTED transition: \(from) → \(to) [\(caller, privacy: .public)]")
            return false
        }

        Logger.quiz.info("State: \(from) → \(to) [\(caller, privacy: .public)]")
        quizState = newState
        if case .askingQuestion = newState { mcqVoiceMatchedKey = nil }

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
                        "index": answered,
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
    var isStoppingRecording = false // internal for QuizViewModel+Recording

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

    /// Whether question TTS is currently playing. The command listener is torn
    /// down during TTS and re-armed after (77.5 windowed lifecycle / the 1a19438
    /// self-trigger guard) — `currentCommandScreen` returns nil while this is true
    /// so the recognizer never hears its own playback. Internal for +Audio/+CommandListener.
    var isPlayingQuestionTTS: Bool = false

    /// The option key matched by voice on an MCQ question (nil between questions).
    /// Drives the `selected` highlight in MCQOptionPicker without waiting for tap.
    @Published var mcqVoiceMatchedKey: String?

    // MARK: - Dependencies

    let networkService: NetworkServiceProtocol
    let audioService: AudioServiceProtocol
    let persistenceStore: PersistenceStoreProtocol
    let silenceDetectionService: SilenceDetectionServiceProtocol?
    let sttService: ElevenLabsSTTServiceProtocol?

    /// Language-neutral earcon player (#77, task 77.10). A settable property (not
    /// an init param) so the ~15 existing call sites are untouched and tests can
    /// inject a `MockEarconPlayer`. Cues route through `emitEarcon(_:)`, which
    /// suppresses them during question TTS.
    var earconPlayer: EarconPlaying = SystemEarconPlayer()

    private var cancellables = Set<AnyCancellable>()

    /// Single owner for every long-lived `Task` this view model spawns.
    /// Each call site stores its task under a `TaskKey`; `resetState()` calls
    /// `cancelAll()` instead of duplicating ten cancel-and-nil lines.
    let taskBag = TaskBag() // internal for QuizViewModel+Timers/+Recording/+Audio

    // Whether the current recording is a re-record (bypasses all timers) (internal for QuizViewModel+Timers)
    var isRerecording: Bool = false

    // Consecutive transcription failures for 3-tier error escalation
    var consecutiveTranscriptionFailures: Int = 0 // internal for QuizViewModel+Recording

    // Next question data (from response, displayed after showing results)
    private var nextQuestionAudioUrl: String?
    private var nextQuestion: Question?

    // Current question audio URL for "repeat" command
    var currentQuestionAudioUrl: String? // internal for QuizViewModel+Audio

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

        // #67 Part A: recover from a phone-call/Siri interruption that tears down
        // streaming recording — leave .recording and reset streaming STT so no
        // recording is stranded after the call.
        self.audioService.onInterruptionBegan = { [weak self] in
            self?.handleAudioInterruption()
        }

        // Load saved settings and stats
        settings = persistenceStore.loadSettings()
        quizStats = persistenceStore.loadStats()

        // Auto-persist settings whenever they change
        $settings
            .dropFirst() // Skip the initial value replayed by @Published
            .removeDuplicates() // Only persist actual changes (QuizSettings is Equatable)
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
        autoAdvanceEnabled = true // Reset auto-advance for new quiz
        isRerecording = false
        consecutiveTranscriptionFailures = 0

        // Use provided parameters or fall back to settings
        let quizMaxQuestions = maxQuestions ?? settings.numberOfQuestions
        let quizDifficulty = difficulty ?? settings.difficulty
        let quizLanguage = language ?? settings.language

        // Check if question history is at capacity
        if persistenceStore.isAtCapacity {
            setError(
                message: String(localized: "Question history is full. Please reset your history in Settings to continue.", comment: "Shown when saved-question history hit its cap; user must reset history"),
                context: .initialization,
                model: .historyAtCapacity
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
                let audioModeName = selectedAudioMode.name
                Logger.audio.info("🎤 Audio session configured with \(audioModeName, privacy: .public)")
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
               let questionUrl = audioInfo.questionUrl
            {
                await playQuestionAudio(from: questionUrl)
            } else {
                // No audio — start silence detection then recording/timer
                await startSilenceDetectionListening()
                startRecordingOrTimer()
            }

        } catch let error as NetworkError {
            if case let .dailyLimitReached(limitError) = error {
                dailyLimitError = limitError
                showPaywall = true
                transition(to: .idle)
                audioService.deactivateSession()
            } else {
                setError(
                    message: String(localized: "Failed to start quiz: \(error.localizedDescription)", comment: "Quiz could not be started; placeholder is the underlying error"),
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
    /// `model` overrides the derived display model for failures whose copy/CTA
    /// can't be inferred from the error or context (e.g. history at capacity).
    func setError(message: String, context: ErrorContext, error: Error? = nil, model: AppErrorModel? = nil) { // internal for QuizViewModel+Recording
        #if DEBUG
            lastErrorDebugInfo = error.map { Self.formatDebugError($0, displayMessage: message) }
        #endif
        activeErrorModel = model
            ?? error.map { AppErrorModel.from($0, context: context) }
            ?? AppErrorModel.from(context: context)
        transition(to: .error(message: message, context: context))
    }

    /// Handle an error, detecting 429 daily limit and showing paywall instead of error state
    private func handleError(_ error: Error, context: ErrorContext, fallbackMessage: String) {
        if let networkError = error as? NetworkError,
           case let .dailyLimitReached(limitError) = networkError
        {
            dailyLimitError = limitError
            showPaywall = true
            transition(to: .idle)
            audioService.deactivateSession()
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

    /// Refresh usage after a premium purchase. Premium is granted server-side
    /// via IAP (#50) — the client no longer self-grants (the old `setPremium`
    /// call sent no admin key and always 401'd, #60). Just refresh the display.
    func notifyPremiumPurchased() async {
        await refreshUsage()
    }

    /// Whether to retry with a new session (for initialization errors)
    var shouldRetryWithNewSession: Bool {
        if case let .error(_, context) = quizState {
            return context == .initialization
        }
        return false
    }

    /// Retry the last operation based on error context
    func retryLastOperation() async {
        guard case let .error(_, context) = quizState else { return }
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
    func submitMCQAnswer(key _: String, value: String) async {
        guard let sessionId = currentSession?.id else {
            errorMessage = String(localized: "No active session", comment: "Inline error: no quiz session is currently active")
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
            handleError(error, context: .submission, fallbackMessage: String(localized: "Failed to submit answer", comment: "Error prefix when submitting an answer fails; error detail is appended"))
        }
    }

    /// Resubmit an edited text answer
    func resubmitAnswer(_ newAnswer: String, suppressAudio: Bool = false) async {
        guard let sessionId = currentSession?.id else {
            errorMessage = String(localized: "No active session", comment: "Inline error: no quiz session is currently active")
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
            handleError(error, context: .submission, fallbackMessage: String(localized: "Failed to resubmit answer", comment: "Error prefix when resubmitting an edited answer fails; error detail is appended"))

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

        transition(to: .skipping)
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
            handleError(error, context: .submission, fallbackMessage: String(localized: "Failed to skip question", comment: "Error prefix when skipping a question fails; error detail is appended"))

            Logger.quiz.error("❌ Error skipping question: \(error, privacy: .public)")
        }
    }

    /// Open the skip undo-window (#77, task 77.9). A recognized "skip" on the
    /// question screen does NOT commit immediately: it opens a ~2.5 s window that a
    /// tap can abort (`abortSkipUndoWindow`). On expiry (window unaborted) the skip
    /// commits via `skipQuestion()`. Idempotent while a window is already open.
    /// `duration` is injectable so tests don't wait the full 2.5 s.
    ///
    /// Deferred to Session 5: aborting via a spoken cancel word ("stop"/"no") — that
    /// needs the cancel-word listener path that ships with the earcons. This method
    /// leaves the abort seam (`abortSkipUndoWindow`) and the open-event seam
    /// (`onSkipUndoWindowOpened`) ready for it.
    func beginSkipUndoWindow(duration: TimeInterval = UndoWindow.defaultDuration) {
        guard quizState == .askingQuestion, pendingSkipWindow == nil else { return }
        cancelAnswerTimer()
        cancelThinkingTime()
        pendingSkipWindow = UndoWindow(duration: duration)
        emitEarcon(.skipConfirm) // 77.10 skip-confirm tone — undo-window opened
        onSkipUndoWindowOpened?() // observation seam (deferred UI / tests)

        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self, !Task.isCancelled else { return }
            guard self.pendingSkipWindow != nil else { return } // aborted
            self.pendingSkipWindow = nil
            await self.skipQuestion()
        }
        taskBag.add(task, key: .skipUndo)
        Logger.voice.info("⏭️ Skip undo-window opened (\(duration, privacy: .public)s)")
    }

    /// Abort a pending skip (a tap on the undo affordance). No-op if none is open.
    func abortSkipUndoWindow() {
        guard pendingSkipWindow != nil else { return }
        pendingSkipWindow = nil
        taskBag.cancel(.skipUndo)
        Logger.voice.info("↩️ Skip undo-window aborted")
    }

    /// End the current quiz session
    func endQuiz() async {
        guard let sessionId = currentSession?.id else { return }

        cancelAnswerTimer()
        cancelAutoStopRecordingTimer()

        do {
            try await networkService.endSession(sessionId: sessionId)
            persistenceStore.clearSession()
            await stopAnyPlayingAudio() // Await properly (we're async here)
            resetState()

            Logger.quiz.info("🎮 Quiz ended")
        } catch NetworkError.sessionNotFound {
            // Backend 404: the session is already gone (TTL expiry, backend restart, or a
            // prior end). This is *correct* backend behaviour — there is nothing left to clean
            // up server-side. The end-quiz invariant is "tapping X always returns Home", so
            // treat an already-ended session as success rather than stranding the user behind
            // a misleading "session not found" banner.
            Logger.quiz.info("🎮 Session already ended on backend (404) — resetting to home")
            resetToHome()
        } catch {
            // Errors here mean the session may still be live on the backend (e.g. a timeout).
            // Surface a banner so the user knows server-side cleanup may not have happened and
            // can retry; do not silently drop a possibly-live session.
            errorMessage = String(localized: "Failed to end quiz: \(error.localizedDescription)", comment: "Inline error when ending the quiz fails; placeholder is the underlying error")

            Logger.quiz.error("❌ Error ending quiz: \(error, privacy: .public)")
        }
    }

    /// Resume a saved session
    func resumeSession() async {
        guard persistenceStore.currentSessionId != nil else {
            errorMessage = String(localized: "No saved session found", comment: "Inline error: no previously saved quiz session exists to resume")
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

    /// Resume the auto-advance countdown for the *current* result without jumping to the
    /// next question. Distinct from `continueToNext()` (which advances immediately): the
    /// "Resume auto-advance" button must re-arm the countdown so the user stays on the
    /// result screen and the next question is reached via the timer, not instantly (#59.8).
    /// Clears the pause flag first — `startAutoAdvanceCountdown` bails while paused.
    func resumeAutoAdvance() {
        currentQuestionPaused = false

        Task {
            await startAutoAdvanceCountdown(duration: settings.autoAdvanceDelay, audioDuration: 0)
        }

        Logger.quiz.info("▶️ Resuming auto-advance countdown (staying on result)")
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
    /// (internal so the MCQ guard-removal regression can drive it directly — 45.3).
    func startRecordingOrTimer() {
        guard quizState == .askingQuestion else { return }

        if settings.autoRecordEnabled && silenceDetectionService != nil && !isRerecording {
            // Auto-record path: thinking time countdown → auto-start recording
            startThinkingTimeCountdown()
        } else {
            startAnswerTimer()
        }
    }

    func handleQuizResponse(_ response: QuizResponse) async { // internal for QuizViewModel+Recording
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
                message: String(localized: "Could not evaluate your answer. Please try again.", comment: "Shown when the server response contained no evaluation"),
                context: .submission
            )
            return
        }

        // Validate question ID matches between evaluation and current question
        if let evalQuestionId = evaluation.questionId,
           let currentQId = currentQuestion?.id,
           evalQuestionId != currentQId
        {
            Logger.quiz.warning("⚠️ MISMATCH: evaluation.questionId=\(evalQuestionId, privacy: .public) != currentQuestion.id=\(currentQId, privacy: .public)")
        }

        // CRITICAL: Capture the current question for the result state
        // The associated value bundles question + evaluation together,
        // making it impossible to show stale/mismatched data
        guard let question = currentQuestion else {
            setError(message: String(localized: "No question to evaluate", comment: "Inline error: result arrived but there is no current question to pair it with"), context: .general)
            return
        }

        // Update score and question count
        if let participant = response.session.participants.first {
            score = participant.score
            questionsAnswered = participant.answeredCount
        }

        // Update quiz stats (streak tracking)
        if evaluation.result != .skipped {
            streakBeforeLastAnswer = quizStats.currentStreak
            quizStats.recordAnswer(isCorrect: evaluation.isCorrect)
            persistenceStore.saveStats(quizStats)
        }

        // Per-session tallies for the completion breakdown (54.13)
        if evaluation.result == .correct {
            sessionCorrectCount += 1
        } else if evaluation.result == .incorrect {
            sessionIncorrectCount += 1
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
        // #77 (77.5): result window — re-arm the command listener for "next"/"ok"
        // (Session 4 routes them) on top of auto-advance.
        refreshCommandWindow()

        // Auto-extend session TTL to prevent timeout on long drives
        if let sessionId = currentSession?.id {
            Task {
                do {
                    try await networkService.extendSession(sessionId: sessionId, minutes: 30)
                } catch {
                    // Fire-and-forget by design, but warn-log so silent TTL drift (a 404 on a
                    // later endQuiz / extend) is diagnosable rather than invisible (#59.4).
                    Logger.quiz.warning("⚠️ Failed to extend session TTL: \(error, privacy: .public)")
                }
            }
        }

        // 59.7 Bug B: start the auto-advance countdown immediately so the countdown bar is
        // visible the moment the result appears — previously it ran feedback audio first and
        // only started the countdown afterwards, so the bar sat invisible for 3-5s. Feedback
        // audio now plays concurrently (async let) while the countdown runs. The configured
        // delay (default 8s) normally exceeds the feedback length, so playback isn't cut off.
        Task {
            async let feedbackDuration: TimeInterval = {
                guard let audioInfo = response.audio else { return 0.0 }
                // Prioritize base64 (enhanced feedback) over URL (generic feedback)
                if let base64 = audioInfo.feedbackAudioBase64 {
                    return await playFeedbackAudioBase64(base64)
                } else if let feedbackUrl = audioInfo.feedbackUrl {
                    return await playFeedbackAudio(from: feedbackUrl)
                }
                return 0.0
            }()

            await startAutoAdvanceCountdown(duration: settings.autoAdvanceDelay, audioDuration: 0)

            // Keep the feedback audio playing to completion (and surface any failure log)
            // before this task ends; the countdown above is already running concurrently.
            _ = await feedbackDuration
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
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds

        // Determine next state based on session status
        if let session = currentSession, session.isFinished {
            // Quiz is complete — record stats
            quizStats.recordQuizCompleted()
            persistenceStore.saveStats(quizStats)
            transition(to: .finished)
            persistenceStore.clearSession()
            // Release the audio session so Spotify/podcasts resume full volume.
            audioService.deactivateSession()

            let finalScore = score
            Logger.quiz.info("🎮 Quiz finished! Final score: \(finalScore, privacy: .public)")
        } else {
            // More questions remain - NOW update currentQuestion with stored next question
            // This ensures the next question only appears AFTER showing results
            currentQuestion = nextQuestion
            nextQuestion = nil // Clear after use

            // Transition to asking question state
            transition(to: .askingQuestion)

            // Play next question audio if available
            if let questionUrl = nextQuestionAudioUrl {
                await playQuestionAudio(from: questionUrl)
                nextQuestionAudioUrl = nil // Clear after use
            } else {
                // No audio — auto-record or timer based on settings
                startRecordingOrTimer()
            }

            let nextQuestionText = currentQuestion?.question ?? "unknown"
            Logger.quiz.info("❓ Showing next question: \(nextQuestionText, privacy: .public)")
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
        // Release audio session so Spotify/podcasts resume full volume after
        // the quiz is torn down (resetToHome / endQuiz / paywall reset).
        audioService.deactivateSession()
        currentQuestion = nil
        currentSession = nil
        score = 0.0
        questionsAnswered = 0
        sessionCorrectCount = 0
        sessionIncorrectCount = 0
        errorMessage = nil
        nextQuestionAudioUrl = nil
        nextQuestion = nil
        currentQuestionAudioUrl = nil
        autoAdvanceCountdown = 0
        answerTimerCountdown = 0
        thinkingTimeCountdown = 0
        currentQuestionPaused = false
        isQuizModalPresented = false
        autoAdvanceEnabled = true
        isRerecording = false
        isAutoRecording = false
        speechDetectedDuringAutoRecord = false
        isStreamingSTT = false
        liveTranscript = ""
        pendingResponse = nil
        transcribedAnswer = ""
        showAnswerConfirmation = false
        // Ending a quiz from the minimized widget must dismiss the widget —
        // otherwise a stale card floats over Home (#54 task 54.6).
        isMinimized = false
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
