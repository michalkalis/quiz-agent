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
        case .finished: return ["idle", "startingQuiz"]
        case .error: return ["idle", "askingQuestion", "startingQuiz"]
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

    // Paywall/quota/usage slice — owned by EntitlementReconciler (#113 T1).
    // Permanent forwarding accessors (decision 2) so views/tests keep binding
    // QuizViewModel; change notifications ride the re-published child
    // `objectWillChange` wired in `init`. Settable because ContentView
    // dismisses via `showPaywall = false` and tests seed usage/quota directly.
    var showPaywall: Bool {
        get { entitlementReconciler.showPaywall }
        set { entitlementReconciler.showPaywall = newValue }
    }

    var quotaLimitError: QuotaLimitError? {
        get { entitlementReconciler.quotaLimitError }
        set { entitlementReconciler.quotaLimitError = newValue }
    }

    var usageInfo: UsageInfo? {
        get { entitlementReconciler.usageInfo }
        set { entitlementReconciler.usageInfo = newValue }
    }

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

    // Minimize state
    @Published var isMinimized: Bool = false

    // MARK: - Command Capture Phase (#77, task 77.4)

    /// Additive capture-phase observable (E-state) — the single source of truth
    /// for earcons (77.10) and the deferred recording UI (P5). SEPARATE axis from
    /// `quizState`; driven off injected audio-lifecycle events via
    /// `applyCaptureEvent(_:)`. Deliberately NOT part of QuizState/validTransitions.
    @Published private(set) var commandCapturePhase: CommandCapturePhase = .idle

    /// Most recent screen-scoped command the listener recognized this session
    /// (#96 P2). Powers the release-visible Settings diagnostics row so the
    /// founder can confirm on-device that recognition is firing. `nil` until the
    /// first command is heard.
    @Published private(set) var lastRecognizedCommand: VoiceCommand?

    /// Observable mirror of the recognizer's command availability (#96 S2). The
    /// service's `commandAvailability` is a plain (non-`@Published`) property; on a
    /// fresh install the en-US model installs asynchronously and flips it to
    /// `.ready` well after Home has armed the listener — with no observable signal,
    /// SwiftUI never re-renders and the "LISTENING FOR COMMANDS" bar stays hidden
    /// even though commands now work. We seed this from the service on start and
    /// keep it in sync via `commandAvailabilityUpdates`, so `commandListenerHint`
    /// (and the Settings status row) react to availability changes live.
    @Published private(set) var commandAvailability: VoiceCommandAvailability = .unknown

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

    /// Record the most recently recognized command for the release diagnostics
    /// row (#96 P2). Lives in the main file so `lastRecognizedCommand`'s private
    /// setter is honored (the CommandListener extension is a separate file).
    func noteRecognizedCommand(_ command: VoiceCommand) {
        lastRecognizedCommand = command
    }

    /// Single funnel for every earcon (77.10). Suppresses cues during question
    /// TTS (`isPlayingQuestionTTS`) so a tone never plays over the spoken
    /// question — the one hard rule for the language-neutral cue set.
    /// The "Recording sounds" setting (#68) gates only the mic-live / got-it
    /// pair; command-ack and skip cues stay on as driving-safety feedback.
    func emitEarcon(_ earcon: Earcon) {
        guard !isPlayingQuestionTTS else { return }
        if earcon == .micLive || earcon == .gotIt {
            guard settings.recordingSoundsEnabled else { return }
        }
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

    // MARK: - Audio Device State — forwarded to AudioDeviceState (#113 T2)

    // Audio device slice — owned by AudioDeviceState. Permanent forwarding
    // accessors (decision 2) so views/tests keep binding QuizViewModel;
    // change notifications ride the re-published child `objectWillChange`
    // wired in `init`.
    var selectedAudioMode: AudioMode { audioDeviceState.selectedAudioMode }

    /// Available input devices from AudioService
    var availableInputDevices: [AudioDevice] { audioDeviceState.availableInputDevices }

    /// Currently selected input device (nil = automatic)
    var selectedInputDevice: AudioDevice? { audioDeviceState.selectedInputDevice }

    /// Current output device name for display
    var currentOutputDeviceName: String { audioDeviceState.currentOutputDeviceName }

    /// Display name for current input device
    var currentInputDeviceName: String { audioDeviceState.currentInputDeviceName }

    /// Sheet presentation state for microphone picker. Settable because
    /// SettingsView/HomeView present the sheet via `$viewModel.showingMicrophonePicker`.
    var showingMicrophonePicker: Bool {
        get { audioDeviceState.showingMicrophonePicker }
        set { audioDeviceState.showingMicrophonePicker = newValue }
    }

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
        // #110 Bug 3: .finished never cleared isMinimized, so a stale
        // MinimizedQuizView floated over CompletionView with nothing to dismiss it.
        if case .finished = newState { isMinimized = false }

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

    /// Simple Bool flag to prevent concurrent proceedToNextQuestion calls (#100).
    /// Safe because this class is @MainActor — all access is serialized on the main thread.
    private var isAdvancing = false

    /// Monotonic submission generation (#79). Bumped at the start of EVERY
    /// submission-initiating path — `resubmitAnswer`, `submitMCQAnswer`,
    /// `skipQuestion` — before its first `await`. A committed-voice-transcript
    /// handler that is suspended mid-flight captures the epoch on entry and, after
    /// each await, aborts if it moved: so a typed answer submitted during that
    /// window can't trigger a second concurrent submission or resurrect the stale
    /// voice confirmation sheet. Internal for the +Recording extension / tests.
    var submissionEpoch = 0

    /// Single-flight guard for `resubmitAnswer` (#79): the typed-answer TextField's
    /// `.onSubmit` and its send button can both fire, and both call `resubmitAnswer`.
    /// Held for the whole submission via `defer` so exactly one proceeds. Does not
    /// gate the `confirmAnswer` voice entry (still a single call site).
    var isSubmittingAnswer = false

    /// Single-flight guard for `startNewQuiz` (#110): "Try Again"/"Play Again" can be
    /// double-tapped before the first `createSession` resolves. Held for the whole
    /// flow via `defer` so exactly one session is created, mirroring `isSubmittingAnswer`.
    var isStarting = false

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
    /// so the recognizer never hears its own playback. Internal for +CommandListener;
    /// AudioDeviceState writes it via injected closures (#113 T2, decision 4).
    var isPlayingQuestionTTS: Bool = false

    /// The option key matched by voice on an MCQ question (nil between questions).
    /// Drives the `selected` highlight in MCQOptionPicker without waiting for tap.
    @Published var mcqVoiceMatchedKey: String?

    /// Whether the app scene is foreground-active. Flipped synchronously by
    /// `handleScenePhase(_:)` BEFORE any teardown so a racing
    /// `refreshCommandWindow()` or a post-TTS `startSilenceDetectionListening()`
    /// can never re-arm the mic mid-transition to background (mic-in-background
    /// fix). `currentCommandScreen` returns nil while this is false.
    /// Internal for +CommandListener/+Audio/+Recording/+ScenePhase.
    var isAppForeground: Bool = true

    // MARK: - Dependencies

    let networkService: NetworkServiceProtocol
    let audioService: AudioServiceProtocol
    let persistenceStore: PersistenceStoreProtocol
    let silenceDetectionService: SilenceDetectionServiceProtocol
    let sttService: ElevenLabsSTTServiceProtocol?

    /// Language-neutral earcon player (#77, task 77.10). A settable property (not
    /// an init param) so the ~15 existing call sites are untouched and tests can
    /// inject a `MockEarconPlayer`. Cues route through `emitEarcon(_:)`, which
    /// suppresses them during question TTS.
    var earconPlayer: EarconPlaying = SystemEarconPlayer()

    private var cancellables = Set<AnyCancellable>()

    /// Long-lived observer of `silenceDetectionService.commandAvailabilityUpdates`,
    /// mirroring each change into `commandAvailability`. Deliberately NOT in
    /// `taskBag` (which is quiz-scoped and cleared by `resetState`) — availability
    /// changes span the whole app lifetime. Cancelled in `deinit`.
    private var commandAvailabilityTask: Task<Void, Never>?

    /// Entitlement/usage/paywall slice owner (#113 T1). The façade owns the
    /// child, re-publishes its `objectWillChange`, and re-exposes the slice
    /// via the forwarding accessors above (decision 2) — views never bind it
    /// directly.
    let entitlementReconciler: EntitlementReconciler

    /// Audio slice owner (#113 T2): device management, audio-mode switching,
    /// the silence-detection choke points, and TTS/feedback playback. The
    /// façade owns the child, re-publishes its `objectWillChange`, and
    /// re-exposes the slice via the forwarding accessors above (decision 2).
    /// `lazy` so the injected closures can capture `self` weakly — built by
    /// `makeAudioDeviceState()` on first touch (the `init` re-publish sink).
    private(set) lazy var audioDeviceState: AudioDeviceState = makeAudioDeviceState()

    /// Single owner for every long-lived `Task` this view model spawns.
    /// Each call site stores its task under a `TaskKey`; `resetState()` calls
    /// `cancelAll()` instead of duplicating ten cancel-and-nil lines.
    let taskBag = TaskBag() // internal for QuizViewModel+Timers/+Recording; shared with AudioDeviceState

    // Whether the current recording is a re-record (bypasses all timers) (internal for QuizViewModel+Timers)
    var isRerecording: Bool = false

    // Consecutive transcription failures for 3-tier error escalation
    var consecutiveTranscriptionFailures: Int = 0 // internal for QuizViewModel+Recording

    // Next question data (from response, displayed after showing results)
    private var nextQuestionAudioUrl: String?
    private var nextQuestion: Question?

    // Current question audio URL for "repeat" command — written by
    // AudioDeviceState via injected closures (#113 T2, decision 4); moves to
    // RecordingCoordinator in S5.
    var currentQuestionAudioUrl: String?

    // MARK: - Initialization

    init(
        networkService: NetworkServiceProtocol,
        audioService: AudioServiceProtocol,
        persistenceStore: PersistenceStoreProtocol,
        silenceDetectionService: SilenceDetectionServiceProtocol = SilenceDetectionService(),
        sttService: ElevenLabsSTTServiceProtocol? = nil,
        isLocallyEntitled: @escaping @MainActor () -> Bool = { false }
    ) {
        self.networkService = networkService
        self.audioService = audioService
        self.persistenceStore = persistenceStore
        self.silenceDetectionService = silenceDetectionService
        self.sttService = sttService
        // #113 T1: the entitlement/usage/paywall slice lives in its own child;
        // its init fires the launch reconcile (#102 finding 1) — single-flight,
        // bounded backoff, failure logged only (server stays source of truth).
        entitlementReconciler = EntitlementReconciler(
            networkService: networkService,
            isLocallyEntitled: isLocallyEntitled
        )

        // Seed + observe the recognizer availability so the "LISTENING FOR
        // COMMANDS" indicator is reactive (see `commandAvailability`). Seeding
        // catches whatever the service resolved before this view-model existed;
        // the stream then keeps it in sync — including the async `.ready` flip
        // when the en-US model finishes installing after launch.
        commandAvailability = silenceDetectionService.commandAvailability
        commandAvailabilityTask = Task { [weak self, silence = silenceDetectionService] in
            for await availability in silence.commandAvailabilityUpdates {
                guard let self, !Task.isCancelled else { break }
                self.commandAvailability = availability
            }
        }

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

        // Re-publish child slice changes so views bound to the façade
        // re-render (#113 decision 2 — views keep @ObservedObject QuizViewModel).
        entitlementReconciler.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        audioDeviceState.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// #113 T2: builds the audio child. Every closure captures the façade
    /// weakly — the child is façade-owned so `self` outlives it; `weak` just
    /// breaks the ownership cycle (façade → child → closure → façade). Each
    /// closure is the minimal scoped read/write of decision 4 — never a vm ref.
    private func makeAudioDeviceState() -> AudioDeviceState {
        AudioDeviceState(
            audioService: audioService,
            networkService: networkService,
            silenceDetectionService: silenceDetectionService,
            taskBag: taskBag,
            settings: { [weak self] in self?.settings ?? .default },
            setAudioMode: { [weak self] in self?.settings.audioMode = $0 },
            setPreferredInputDeviceId: { [weak self] in self?.settings.preferredInputDeviceId = $0 },
            setMuted: { [weak self] in self?.settings.isMuted = $0 },
            isAppForeground: { [weak self] in self?.isAppForeground ?? false },
            isAskingQuestion: { [weak self] in self?.quizState == .askingQuestion },
            isRerecording: { [weak self] in self?.isRerecording ?? false },
            isPlayingQuestionTTS: { [weak self] in self?.isPlayingQuestionTTS ?? false },
            setPlayingQuestionTTS: { [weak self] in self?.isPlayingQuestionTTS = $0 },
            currentQuestionAudioUrl: { [weak self] in self?.currentQuestionAudioUrl },
            setCurrentQuestionAudioUrl: { [weak self] in self?.currentQuestionAudioUrl = $0 },
            setErrorMessage: { [weak self] in self?.errorMessage = $0 },
            onBargeIn: { [weak self] in await self?.handleBargeIn() },
            startCommandConsumer: { [weak self] in self?.startCommandConsumer() },
            stopCommandConsumer: { [weak self] in self?.stopCommandConsumer() },
            startThinkingTimeCountdown: { [weak self] in self?.startThinkingTimeCountdown() },
            startAnswerTimer: { [weak self] in self?.startAnswerTimer() }
        )
    }

    deinit {
        // Availability observer lives outside `taskBag`; end it explicitly.
        commandAvailabilityTask?.cancel()
    }

    // MARK: - Quiz Flow

    /// Start a new quiz session
    func startNewQuiz(
        maxQuestions: Int? = nil,
        difficulty: String? = nil,
        language: String? = nil,
        packId: String? = nil
    ) async {
        // #110: startNewQuiz is legal only from {.idle, .error, .finished} (cold
        // start, Try Again, Play Again). Check single-flight BEFORE the transition
        // attempt so a double-tap short-circuits without logging a spurious
        // rejected transition, then hold isStarting for the whole flow via defer,
        // mirroring isSubmittingAnswer (#79).
        guard !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        guard transition(to: .startingQuiz) else { return }
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
                categories: settings.categories,
                userId: persistenceStore.deviceId,
                includeImages: settings.includeImageQuestions,
                packId: packId
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

        } catch {
            await handleError(error, context: .initialization, fallbackMessage: String(localized: "Failed to start quiz", comment: "Quiz could not be started; error detail is appended"))

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
    func handleError(_ error: Error, context: ErrorContext, fallbackMessage: String) async { // internal for QuizViewModel+Recording
        if let networkError = error as? NetworkError,
           case let .quotaLimitReached(limitError) = networkError
        {
            let entitlementConfirmed = await entitlementReconciler.resyncBeforePaywallIfLocallyEntitled()
            audioService.deactivateSession()
            if entitlementConfirmed {
                // #102 review follow-up: skip the paywall when the resync just
                // confirmed the user is entitled — ask them to retry instead.
                // (setError transitions to .error directly from the in-flight state.)
                setError(
                    message: String(localized: "Your subscription just synced — please try again.", comment: "Shown after a 429 quota error self-resolves via entitlement resync; user should retry their last action"),
                    context: context
                )
            } else {
                entitlementReconciler.presentQuotaPaywall(limitError)
                transition(to: .idle)
            }
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

    // MARK: - Entitlements / paywall — forwarded to EntitlementReconciler (#113 T1)

    /// Proactive paywall entry (#93) — see `EntitlementReconciler.presentPaywall`.
    func presentPaywall() {
        entitlementReconciler.presentPaywall()
    }

    /// Fetch current usage info — see `EntitlementReconciler.refreshUsage`.
    func refreshUsage() async {
        await entitlementReconciler.refreshUsage()
    }

    /// Post-purchase/restore sync — see `EntitlementReconciler.notifyPremiumPurchased`.
    /// (`StoreManager` relies on the returned entitlement flag.)
    @discardableResult
    func notifyPremiumPurchased() async -> Bool {
        await entitlementReconciler.notifyPremiumPurchased()
    }

    /// Launch/foreground entitlement reconcile (single-flight) — see
    /// `EntitlementReconciler.reconcileEntitlements`. Called from
    /// `handleScenePhase(.active)`; the launch kick fires in the child's `init`.
    func reconcileEntitlements() async {
        await entitlementReconciler.reconcileEntitlements()
    }

    // MARK: - Audio — forwarded to AudioDeviceState (#113 T2)

    // Permanent decision-2 forwards: every one has production callers today
    // (views, MAIN quiz flow, or the +Recording/+CommandListener/+ScenePhase
    // extensions whose extracts will inject the child's primitives instead —
    // S3/S5 re-point them).

    /// Shared silence-detection choke point — see `AudioDeviceState.startSilenceDetectionListening`.
    func startSilenceDetectionListening() async {
        await audioDeviceState.startSilenceDetectionListening()
    }

    /// Shared silence-detection choke point — see `AudioDeviceState.stopSilenceDetectionListening`.
    func stopSilenceDetectionListening() {
        audioDeviceState.stopSilenceDetectionListening()
    }

    /// Question TTS + post-TTS timer/recording arming — see `AudioDeviceState.playQuestionAudio`.
    func playQuestionAudio(from urlString: String) async {
        await audioDeviceState.playQuestionAudio(from: urlString)
    }

    /// See `AudioDeviceState.canReplayAudio` (#59.5).
    var canReplayAudio: Bool { audioDeviceState.canReplayAudio }

    /// On-demand question replay — see `AudioDeviceState.replayQuestionAudio`.
    func replayQuestionAudio() async {
        await audioDeviceState.replayQuestionAudio()
    }

    /// See `AudioDeviceState.playFeedbackAudio(from:)`.
    func playFeedbackAudio(from urlString: String) async -> TimeInterval {
        await audioDeviceState.playFeedbackAudio(from: urlString)
    }

    /// See `AudioDeviceState.playFeedbackAudioBase64(_:)`.
    func playFeedbackAudioBase64(_ base64: String) async -> TimeInterval {
        await audioDeviceState.playFeedbackAudioBase64(base64)
    }

    /// See `AudioDeviceState.toggleMute` (founder bug 2026-07-11).
    func toggleMute() async {
        await audioDeviceState.toggleMute()
    }

    /// See `AudioDeviceState.stopAnyPlayingAudio`.
    func stopAnyPlayingAudio() async {
        await audioDeviceState.stopAnyPlayingAudio()
    }

    /// See `AudioDeviceState.toggleAudioMode`.
    func toggleAudioMode() {
        audioDeviceState.toggleAudioMode()
    }

    /// See `AudioDeviceState.refreshAudioDevices`.
    func refreshAudioDevices() {
        audioDeviceState.refreshAudioDevices()
    }

    /// See `AudioDeviceState.setPreferredInputDevice(_:)`.
    func setPreferredInputDevice(_ device: AudioDevice?) {
        audioDeviceState.setPreferredInputDevice(device)
    }

    /// Handle barge-in: user spoke during TTS playback on external audio route.
    /// Stays façade-resident (not in AudioDeviceState) — it fans out into the
    /// recording + timer clusters; the child reaches it via the injected
    /// `onBargeIn` closure (decision 4).
    func handleBargeIn() async {
        guard quizState == .askingQuestion else { return }

        Logger.voice.info("🗣️ Barge-in triggered — stopping TTS and starting recording")

        // 1. Stop TTS immediately
        await stopAnyPlayingAudio()

        // 2. Clear barge-in activation so a re-fire isn't triggered by the
        //    teardown tail of TTS audio.
        silenceDetectionService.setTTSPlaybackActive(false)

        // 3. Wait for audio hardware to settle
        try? await Task.sleep(nanoseconds: 500_000_000)

        // 4. Guard again — state may have changed during sleep
        guard quizState == .askingQuestion else { return }

        // 5. Auto-start recording (same as post-TTS flow)
        cancelAnswerTimer()
        isAutoRecording = true
        await startRecording()
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
        // #110 Bug 4: a fresh MCQ answer is legal only while the question is open
        // (.askingQuestion) or being voice-answered (.recording). A delayed tap
        // submit can fire after its same-key voice twin already submitted and
        // moved the state on — and .showingResult → .processing is a legal
        // transition (owned by resubmitAnswer), so the transition guard below
        // cannot absorb that late duplicate by itself.
        guard quizState == .askingQuestion || quizState == .recording else { return }

        // #110 Bug 2: starting an answer (voice or tap) supersedes any pending skip.
        abortSkipUndoWindow()

        guard let sessionId = currentSession?.id else {
            errorMessage = String(localized: "No active session", comment: "Inline error: no quiz session is currently active")
            return
        }

        submissionEpoch &+= 1 // #79: supersede any suspended voice-transcript handler
        cancelAnswerTimer()
        cancelAutoStopRecordingTimer()
        // #79: a rejected transition means another submission already claimed
        // .processing (e.g. a double-tapped option) — bail instead of firing a
        // second concurrent submit.
        guard transition(to: .processing) else { return }
        errorMessage = nil

        do {
            let response = try await networkService.submitTextInput(
                sessionId: sessionId,
                input: value,
                audio: settings.audioMode != "off"
            )
            await handleQuizResponse(response)
        } catch {
            await handleError(error, context: .submission, fallbackMessage: String(localized: "Failed to submit answer", comment: "Error prefix when submitting an answer fails; error detail is appended"))
        }
    }

    /// Resubmit an edited text answer
    func resubmitAnswer(_ newAnswer: String, suppressAudio: Bool = false) async {
        // #79: single-flight — .onSubmit and the send button can both fire.
        // Held across the whole submission so exactly one proceeds.
        guard !isSubmittingAnswer else { return }
        isSubmittingAnswer = true
        defer { isSubmittingAnswer = false }

        guard let sessionId = currentSession?.id else {
            errorMessage = String(localized: "No active session", comment: "Inline error: no quiz session is currently active")
            return
        }

        submissionEpoch &+= 1 // #79: supersede any suspended voice-transcript handler

        // #79: a committed-voice-transcript handler may be suspended mid-flight
        // (inside its STT disconnect) with the confirmation sheet about to appear.
        // Dismiss the sheet + auto-confirm and drop the STT event listener up front
        // so the typed answer wins and no stale voice sheet resurfaces.
        showAnswerConfirmation = false
        cancelAutoConfirm()
        taskBag.cancel(.sttEvent)

        // Stop any in-flight voice machinery so the typed answer wins the race
        // against a silent auto-stop submission. Answer/thinking timers are left
        // running on purpose — they no-op once state ≠ .askingQuestion.
        taskBag.cancel(.voiceSubmission)
        cancelAutoStopRecordingTimer()
        cancelSilenceDetection()
        isAutoRecording = false
        speechDetectedDuringAutoRecord = false
        // Streaming STT can still be live even after the committed-transcript
        // handler left .recording (it suspends in disconnect() before flipping
        // state), so tear it down regardless of quizState. Batch recording is
        // only ever live while .recording.
        if isStreamingSTT {
            cleanupStreamingSTT()
        } else if quizState == .recording {
            _ = try? await audioService.stopRecording()
        }

        // The confirmation modal already moved us to .processing in
        // handleCommittedTranscript; only transition when called from a
        // pre-modal state (e.g., still .recording on the batch path). A rejected
        // transition (#79) means the state can't legally reach .processing — bail
        // rather than submit from a bad state.
        if quizState != .processing {
            guard transition(to: .processing) else { return }
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
            await handleError(error, context: .submission, fallbackMessage: String(localized: "Failed to resubmit answer", comment: "Error prefix when resubmitting an edited answer fails; error detail is appended"))

            Logger.network.error("❌ Error resubmitting answer: \(error, privacy: .public)")
        }
    }

    /// Skip the current question
    func skipQuestion() async {
        guard let sessionId = currentSession?.id else { return }

        submissionEpoch &+= 1 // #79: supersede any suspended voice-transcript handler
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
            await handleError(error, context: .submission, fallbackMessage: String(localized: "Failed to skip question", comment: "Error prefix when skipping a question fails; error detail is appended"))

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
            // #110 Bug 2: a pending skip is only ever committed while the quiz is
            // still asking the question — starting an answer (voice or tap)
            // supersedes it. Without this recheck, speaking/tapping during the
            // window let expiry commit skipQuestion() mid-recording, leaving the
            // streaming mic live into the result.
            guard self.quizState == .askingQuestion else {
                self.pendingSkipWindow = nil
                return
            }
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

        if settings.autoRecordEnabled && !isRerecording {
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
        // Guard against concurrent calls (safe: @MainActor serializes access).
        // Checked-and-set before any `await` so a second concurrent call
        // (double-tap Next, or Next racing auto-advance) is a silent no-op
        // instead of clobbering state the first call already advanced (#100).
        guard !isAdvancing else {
            Logger.quiz.warning("⚠️ proceedToNextQuestion already in progress, ignoring duplicate call")
            return
        }
        isAdvancing = true
        defer { isAdvancing = false }

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
        isAdvancing = false
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
