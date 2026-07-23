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

    // Derived projections over `currentSession` (#113 T7) — no stored backing,
    // so they can never drift from the session (kills the stale-projection bug
    // where "Play Again" carried the finished quiz's totals into the new quiz's
    // first render). Change notifications ride `currentSession`'s @Published.
    var score: Double { currentSession?.participants.first?.score ?? 0.0 }
    var questionsAnswered: Int { currentSession?.participants.first?.answeredCount ?? 0 }

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

    /// Load status of the `/usage` mirror — lets the Home card distinguish
    /// "still loading" from "failed" so it renders a retry placeholder instead
    /// of silently disappearing on a transient fetch failure (#FIX2).
    var usageLoadState: EntitlementReconciler.UsageLoadState {
        entitlementReconciler.usageLoadState
    }

    // MARK: - Answer Confirmation — forwarded to RecordingCoordinator (#113 T5)

    // Confirmation-modal slice — owned by RecordingCoordinator. Permanent
    // forwarding accessors (decision 2) so views/tests keep binding
    // QuizViewModel; change notifications ride the re-published child
    // `objectWillChange` wired in `init`. Settable: QuestionView binds the
    // sheet + transcript (`$viewModel.…`) and the façade itself writes them
    // (resubmitAnswer, resetState).
    var showAnswerConfirmation: Bool {
        get { recordingCoordinator.showAnswerConfirmation }
        set { recordingCoordinator.showAnswerConfirmation = newValue }
    }

    var transcribedAnswer: String {
        get { recordingCoordinator.transcribedAnswer }
        set { recordingCoordinator.transcribedAnswer = newValue }
    }

    /// Auto-confirm countdown — owned by `ConfirmationState` inside
    /// RecordingCoordinator (#113 T7, its semantic owner); QuizTimersController
    /// ticks it via the injected write closure pointed at the child.
    var autoConfirmCountdown: Int {
        get { recordingCoordinator.autoConfirmCountdown }
        set { recordingCoordinator.autoConfirmCountdown = newValue }
    }

    // MARK: - Timers — forwarded to QuizTimersController (#113 T4)

    // Timer slice — owned by QuizTimersController. Permanent forwarding
    // accessors (decision 2) so views/tests keep binding QuizViewModel;
    // change notifications ride the re-published child `objectWillChange`
    // wired in `init`. Settable: the façade writes them (resetState,
    // pauseQuiz/resumeAutoAdvance/continueToNext/proceedToNextQuestion,
    // startNewQuiz) and tests seed them directly.

    /// Auto-advance countdown for ResultView binding (single source of truth)
    /// — see `QuizTimersController.autoAdvanceCountdown`.
    var autoAdvanceCountdown: Int {
        get { quizTimersController.autoAdvanceCountdown }
        set { quizTimersController.autoAdvanceCountdown = newValue }
    }

    /// Answer timer countdown (visible on QuestionView) — see
    /// `QuizTimersController.answerTimerCountdown`.
    var answerTimerCountdown: Int {
        get { quizTimersController.answerTimerCountdown }
        set { quizTimersController.answerTimerCountdown = newValue }
    }

    /// Thinking time countdown (visible on QuestionView before auto-recording)
    /// — see `QuizTimersController.thinkingTimeCountdown`.
    var thinkingTimeCountdown: Int {
        get { quizTimersController.thinkingTimeCountdown }
        set { quizTimersController.thinkingTimeCountdown = newValue }
    }

    /// Per-question pause state (resets on next question) — see
    /// `QuizTimersController.currentQuestionPaused`.
    var currentQuestionPaused: Bool {
        get { quizTimersController.currentQuestionPaused }
        set { quizTimersController.currentQuestionPaused = newValue }
    }

    // Minimize state
    @Published var isMinimized: Bool = false

    // MARK: - Voice Commands — forwarded to VoiceCommandCoordinator (#113 T3)

    // Voice-command slice — owned by VoiceCommandCoordinator. Permanent
    // forwarding accessors (decision 2) so views keep binding QuizViewModel;
    // change notifications ride the re-published child `objectWillChange`
    // wired in `init`.

    /// Recognizer availability mirror — see `VoiceCommandCoordinator.commandAvailability`
    /// (SettingsView status row).
    var commandAvailability: VoiceCommandAvailability { voiceCommandCoordinator.commandAvailability }

    /// Release diagnostics (#96 P2) — see `VoiceCommandCoordinator.lastRecognizedCommand`
    /// (SettingsView diagnostics row).
    var lastRecognizedCommand: VoiceCommand? { voiceCommandCoordinator.lastRecognizedCommand }

    /// Home voice-start flag — see `VoiceCommandCoordinator.voiceStartOnHomeEnabled`
    /// (HomeView.onAppear).
    var voiceStartOnHomeEnabled: Bool { voiceCommandCoordinator.voiceStartOnHomeEnabled }

    /// "LISTENING FOR COMMANDS" indicator hint — see
    /// `VoiceCommandCoordinator.commandListenerHint` (CmdListenBar call sites).
    var commandListenerHint: String? { voiceCommandCoordinator.commandListenerHint }

    /// Fire-and-forget command-window sync for synchronous call sites
    /// (MAIN / +ScenePhase / SettingsView / HomeView; RecordingCoordinator
    /// reaches it via an injected closure) — see
    /// `VoiceCommandCoordinator.refreshCommandWindow`.
    func refreshCommandWindow() {
        voiceCommandCoordinator.refreshCommandWindow()
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
        // T7 (decision 8): leaving the recording/processing phase-pair drops the
        // confirmation + capture subsets atomically via the owner child — never
        // mid-pair (recording → processing keeps in-flight state), and never the
        // question-scoped fields (see `resetOnPhaseExit`).
        let recordingPair = ["recording", "processing"]
        if recordingPair.contains(from), !recordingPair.contains(to) {
            recordingCoordinator.resetOnPhaseExit()
        }
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
    /// voice confirmation sheet. Read by RecordingCoordinator via an injected
    /// closure; internal for tests.
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

    // MARK: - Auto-Record State

    /// Whether auto-record is active for the current recording (for UI hints).
    /// Multi-writer cross-cluster flag (Recording *and* Timers write) — stays
    /// façade-resident (decision 4); children reach it via injected closures.
    @Published var isAutoRecording: Bool = false

    // MARK: - Streaming STT — forwarded to RecordingCoordinator (#113 T5)

    /// Live transcript from ElevenLabs (updates as user speaks) — see
    /// `RecordingCoordinator.liveTranscript`. Settable: the DEBUG UI-test
    /// seed (AppState) and `resetState` write it.
    var liveTranscript: String {
        get { recordingCoordinator.liveTranscript }
        set { recordingCoordinator.liveTranscript = newValue }
    }

    /// Whether streaming STT is active — see `RecordingCoordinator.isStreamingSTT`.
    var isStreamingSTT: Bool {
        get { recordingCoordinator.isStreamingSTT }
        set { recordingCoordinator.isStreamingSTT = newValue }
    }

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
    /// Internal for +ScenePhase; the child sub-objects read it via injected closures.
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

    /// Voice-command slice owner (#113 T3): capture phase, recognizer
    /// availability mirror, listening window + consumer + routing, and the
    /// skip undo-window. The façade owns the child, re-publishes its
    /// `objectWillChange`, and re-exposes the view-facing slice via the
    /// forwarding accessors above (decision 2). `lazy` so the injected
    /// closures can capture `self` weakly — built by
    /// `makeVoiceCommandCoordinator()` on first touch (the `init` re-publish sink).
    private(set) lazy var voiceCommandCoordinator: VoiceCommandCoordinator = makeVoiceCommandCoordinator()

    /// Timer slice owner (#113 T4): the countdown/pause state + every timer
    /// start/cancel. The façade owns the child, re-publishes its
    /// `objectWillChange`, and re-exposes the slice via the forwarding
    /// accessors above (decision 2). `lazy` so the injected closures can
    /// capture `self` weakly — built by `makeQuizTimersController()` on
    /// first touch (the `init` re-publish sink).
    private(set) lazy var quizTimersController: QuizTimersController = makeQuizTimersController()

    /// Recording + confirmation slice owner (#113 T5): capture lifecycle,
    /// streaming STT, submission, and answer confirmation. The façade owns
    /// the child, re-publishes its `objectWillChange`, and re-exposes the
    /// slice via the forwarding accessors above (decision 2). `lazy` so the
    /// injected closures can capture `self` weakly — built by
    /// `makeRecordingCoordinator()` on first touch (the `init` re-publish sink).
    private(set) lazy var recordingCoordinator: RecordingCoordinator = makeRecordingCoordinator()

    /// Single owner for every long-lived `Task` this view model spawns.
    /// Each call site stores its task under a `TaskKey`; `resetState()` calls
    /// `cancelAll()` instead of duplicating ten cancel-and-nil lines.
    let taskBag = TaskBag() // shared with the child sub-objects as their decision-4 register/cancel handle

    // Whether the current recording is a re-record (bypasses all timers) —
    // multi-writer cross-cluster flag (decision 4): written by
    // RecordingCoordinator, read by QuizTimersController/AudioDeviceState,
    // all via injected closures
    var isRerecording: Bool = false

    // Next question data (from response, displayed after showing results)
    private var nextQuestionAudioUrl: String?
    private var nextQuestion: Question?

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

        // #67 Part A: recover from a phone-call/Siri interruption that tears down
        // streaming recording — leave .recording and reset streaming STT so no
        // recording is stranded after the call.
        self.audioService.onInterruptionBegan = { [weak self] in
            self?.recordingCoordinator.handleAudioInterruption()
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
        voiceCommandCoordinator.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        quizTimersController.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        recordingCoordinator.objectWillChange
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
            currentQuestionAudioUrl: { [weak self] in self?.recordingCoordinator.currentQuestionAudioUrl },
            setCurrentQuestionAudioUrl: { [weak self] in self?.recordingCoordinator.currentQuestionAudioUrl = $0 },
            setErrorMessage: { [weak self] in self?.errorMessage = $0 },
            onBargeIn: { [weak self] in await self?.handleBargeIn() },
            startCommandConsumer: { [weak self] in self?.voiceCommandCoordinator.startCommandConsumer() },
            stopCommandConsumer: { [weak self] in self?.voiceCommandCoordinator.stopCommandConsumer() },
            startThinkingTimeCountdown: { [weak self] in self?.quizTimersController.startThinkingTimeCountdown() },
            startAnswerTimer: { [weak self] in self?.quizTimersController.startAnswerTimer() }
        )
    }

    /// #113 T3: builds the voice-command child. Every closure captures the
    /// façade weakly — the child is façade-owned so `self` outlives it; `weak`
    /// just breaks the ownership cycle (façade → child → closure → façade).
    /// Each closure is the minimal scoped read/write of decision 4 — never a
    /// vm ref. The recording fan-out targets point at RecordingCoordinator
    /// per the cross-child-via-façade pattern (#113 T5).
    private func makeVoiceCommandCoordinator() -> VoiceCommandCoordinator {
        VoiceCommandCoordinator(
            silenceDetectionService: silenceDetectionService,
            taskBag: taskBag,
            settings: { [weak self] in self?.settings ?? .default },
            isAppForeground: { [weak self] in self?.isAppForeground ?? false },
            isPlayingQuestionTTS: { [weak self] in self?.isPlayingQuestionTTS ?? false },
            quizState: { [weak self] in self?.quizState ?? .idle },
            startSilenceDetectionListening: { [weak self] in await self?.audioDeviceState.startSilenceDetectionListening() },
            stopSilenceDetectionListening: { [weak self] in self?.audioDeviceState.stopSilenceDetectionListening() },
            emitEarcon: { [weak self] in self?.emitEarcon($0) },
            startNewQuiz: { [weak self] in await self?.startNewQuiz() },
            startRecording: { [weak self] in await self?.recordingCoordinator.startRecording() },
            repeatQuestion: { [weak self] in await self?.repeatQuestion() },
            skipQuestion: { [weak self] in await self?.skipQuestion() },
            confirmAnswer: { [weak self] in await self?.recordingCoordinator.confirmAnswer() },
            rerecordAnswer: { [weak self] in self?.recordingCoordinator.rerecordAnswer() },
            cancelProcessing: { [weak self] in self?.recordingCoordinator.cancelProcessing() },
            continueToNext: { [weak self] in self?.continueToNext() },
            cancelAnswerTimer: { [weak self] in self?.quizTimersController.cancelAnswerTimer() },
            cancelThinkingTime: { [weak self] in self?.quizTimersController.cancelThinkingTime() }
        )
    }

    /// #113 T4: builds the timer child. Every closure captures the façade
    /// weakly — the child is façade-owned so `self` outlives it; `weak` just
    /// breaks the ownership cycle (façade → child → closure → façade). Each
    /// closure is the minimal scoped read/write of decision 4 — never a vm
    /// ref. The recording fan-out targets point at RecordingCoordinator
    /// per the cross-child-via-façade pattern (#113 T5).
    private func makeQuizTimersController() -> QuizTimersController {
        QuizTimersController(
            taskBag: taskBag,
            settings: { [weak self] in self?.settings ?? .default },
            quizState: { [weak self] in self?.quizState ?? .idle },
            isRerecording: { [weak self] in self?.isRerecording ?? false },
            setIsAutoRecording: { [weak self] in self?.isAutoRecording = $0 },
            showAnswerConfirmation: { [weak self] in self?.recordingCoordinator.showAnswerConfirmation ?? false },
            setAutoConfirmCountdown: { [weak self] in self?.recordingCoordinator.autoConfirmCountdown = $0 },
            startRecording: { [weak self] in await self?.recordingCoordinator.startRecording() },
            stopRecordingAndSubmit: { [weak self] in await self?.recordingCoordinator.stopRecordingAndSubmit() },
            confirmAnswer: { [weak self] in await self?.recordingCoordinator.confirmAnswer() },
            proceedToNextQuestion: { [weak self] in await self?.proceedToNextQuestion() }
        )
    }

    /// #113 T5: builds the recording child. Every closure captures the façade
    /// weakly — the child is façade-owned so `self` outlives it; `weak` just
    /// breaks the ownership cycle (façade → child → closure → façade). Each
    /// closure is the minimal scoped read/write of decision 4 — never a vm ref.
    private func makeRecordingCoordinator() -> RecordingCoordinator {
        RecordingCoordinator(
            audioService: audioService,
            networkService: networkService,
            silenceDetectionService: silenceDetectionService,
            sttService: sttService,
            taskBag: taskBag,
            settings: { [weak self] in self?.settings ?? .default },
            quizState: { [weak self] in self?.quizState ?? .idle },
            isAppForeground: { [weak self] in self?.isAppForeground ?? false },
            currentQuestion: { [weak self] in self?.currentQuestion },
            currentSession: { [weak self] in self?.currentSession },
            submissionEpoch: { [weak self] in self?.submissionEpoch ?? 0 },
            isAutoRecording: { [weak self] in self?.isAutoRecording ?? false },
            setIsAutoRecording: { [weak self] in self?.isAutoRecording = $0 },
            setIsRerecording: { [weak self] in self?.isRerecording = $0 },
            setErrorMessage: { [weak self] in self?.errorMessage = $0 },
            setMcqVoiceMatchedKey: { [weak self] in self?.mcqVoiceMatchedKey = $0 },
            transition: { [weak self] state, caller in self?.transition(to: state, caller: caller) ?? false },
            setError: { [weak self] message, context, error in
                self?.setError(message: message, context: context, error: error)
            },
            handleError: { [weak self] error, context, fallback in
                await self?.handleError(error, context: context, fallbackMessage: fallback)
            },
            handleQuizResponse: { [weak self] in await self?.handleQuizResponse($0) },
            submitMCQAnswer: { [weak self] key, value in await self?.submitMCQAnswer(key: key, value: value) },
            resubmitAnswer: { [weak self] answer, suppress in await self?.resubmitAnswer(answer, suppressAudio: suppress) },
            skipQuestion: { [weak self] in await self?.skipQuestion() },
            emitEarcon: { [weak self] in self?.emitEarcon($0) },
            refreshCommandWindow: { [weak self] in self?.voiceCommandCoordinator.refreshCommandWindow() },
            abortSkipUndoWindow: { [weak self] in self?.voiceCommandCoordinator.abortSkipUndoWindow() },
            startAutoConfirmIfEnabled: { [weak self] in self?.quizTimersController.startAutoConfirmIfEnabled() },
            cancelAutoConfirm: { [weak self] in self?.quizTimersController.cancelAutoConfirm() },
            cancelAnswerTimer: { [weak self] in self?.quizTimersController.cancelAnswerTimer() },
            cancelThinkingTime: { [weak self] in self?.quizTimersController.cancelThinkingTime() },
            startAutoStopRecordingTimer: { [weak self] in self?.quizTimersController.startAutoStopRecordingTimer() },
            cancelAutoStopRecordingTimer: { [weak self] in self?.quizTimersController.cancelAutoStopRecordingTimer() },
            stopSilenceDetectionListening: { [weak self] in self?.audioDeviceState.stopSilenceDetectionListening() }
        )
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
        isRerecording = false
        recordingCoordinator.consecutiveTranscriptionFailures = 0

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
                await audioDeviceState.playQuestionAudio(from: questionUrl)
            } else {
                // No audio — start silence detection then recording/timer
                await audioDeviceState.startSilenceDetectionListening()
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
    func setError(message: String, context: ErrorContext, error: Error? = nil, model: AppErrorModel? = nil) { // internal for tests; RecordingCoordinator reaches it via an injected closure
        #if DEBUG
            lastErrorDebugInfo = error.map { Self.formatDebugError($0, displayMessage: message) }
        #endif
        activeErrorModel = model
            ?? error.map { AppErrorModel.from($0, context: context) }
            ?? AppErrorModel.from(context: context)
        transition(to: .error(message: message, context: context))
    }

    /// Handle an error, detecting 429 daily limit and showing paywall instead of error state
    func handleError(_ error: Error, context: ErrorContext, fallbackMessage: String) async { // internal for tests; RecordingCoordinator reaches it via an injected closure
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

    // MARK: - Audio — forwarded to AudioDeviceState (#113 T2)

    // Permanent decision-2 forwards: every one has a verified View/app-target
    // caller (T8 census). Forwards that only MAIN or +ScenePhase called were
    // deleted in T8 — the façade calls `audioDeviceState.x()` directly instead.

    /// See `AudioDeviceState.canReplayAudio` (#59.5).
    var canReplayAudio: Bool { audioDeviceState.canReplayAudio }

    /// On-demand question replay — see `AudioDeviceState.replayQuestionAudio`.
    func replayQuestionAudio() async {
        await audioDeviceState.replayQuestionAudio()
    }

    /// See `AudioDeviceState.toggleMute` (founder bug 2026-07-11).
    func toggleMute() async {
        await audioDeviceState.toggleMute()
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

    // MARK: - Recording — forwarded to RecordingCoordinator (#113 T5)

    // Permanent decision-2 forwards: every one has a verified View/app-target
    // caller (T8 census — QuestionView et al.). Façade- and +ScenePhase-only
    // forwards were deleted in T8; those call `recordingCoordinator.x()` direct.

    /// Mic-button entry — see `RecordingCoordinator.toggleRecording`.
    func toggleRecording() async {
        await recordingCoordinator.toggleRecording()
    }

    /// See `RecordingCoordinator.confirmAnswer`.
    func confirmAnswer() async {
        await recordingCoordinator.confirmAnswer()
    }

    /// See `RecordingCoordinator.beginEditingTranscript`.
    func beginEditingTranscript() {
        recordingCoordinator.beginEditingTranscript()
    }

    /// See `RecordingCoordinator.cancelEditingTranscript`.
    func cancelEditingTranscript() {
        recordingCoordinator.cancelEditingTranscript()
    }

    /// See `RecordingCoordinator.handleAnswerConfirmationDismissed`.
    func handleAnswerConfirmationDismissed() {
        recordingCoordinator.handleAnswerConfirmationDismissed()
    }

    /// See `RecordingCoordinator.rerecordAnswer` (#108A).
    func rerecordAnswer() {
        recordingCoordinator.rerecordAnswer()
    }

    /// See `RecordingCoordinator.cancelProcessing`.
    func cancelProcessing() {
        recordingCoordinator.cancelProcessing()
    }

    /// Handle barge-in: user spoke during TTS playback on external audio route.
    /// Stays façade-resident (not in AudioDeviceState) — it fans out into the
    /// recording + timer clusters; the child reaches it via the injected
    /// `onBargeIn` closure (decision 4).
    func handleBargeIn() async {
        guard quizState == .askingQuestion else { return }

        Logger.voice.info("🗣️ Barge-in triggered — stopping TTS and starting recording")

        // 1. Stop TTS immediately
        await audioDeviceState.stopAnyPlayingAudio()

        // 2. Clear barge-in activation so a re-fire isn't triggered by the
        //    teardown tail of TTS audio.
        silenceDetectionService.setTTSPlaybackActive(false)

        // 3. Wait for audio hardware to settle
        try? await Task.sleep(nanoseconds: 500_000_000)

        // 4. Guard again — state may have changed during sleep
        guard quizState == .askingQuestion else { return }

        // 5. Auto-start recording (same as post-TTS flow)
        quizTimersController.cancelAnswerTimer()
        isAutoRecording = true
        await recordingCoordinator.startRecording()
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
        voiceCommandCoordinator.abortSkipUndoWindow()

        guard let sessionId = currentSession?.id else {
            errorMessage = String(localized: "No active session", comment: "Inline error: no quiz session is currently active")
            return
        }

        submissionEpoch &+= 1 // #79: supersede any suspended voice-transcript handler
        quizTimersController.cancelAnswerTimer()
        quizTimersController.cancelAutoStopRecordingTimer()
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
        quizTimersController.cancelAutoConfirm()
        taskBag.cancel(.sttEvent)

        // Stop any in-flight voice machinery so the typed answer wins the race
        // against a silent auto-stop submission. Answer/thinking timers are left
        // running on purpose — they no-op once state ≠ .askingQuestion.
        taskBag.cancel(.voiceSubmission)
        quizTimersController.cancelAutoStopRecordingTimer()
        recordingCoordinator.cancelSilenceDetection()
        isAutoRecording = false
        recordingCoordinator.speechDetectedDuringAutoRecord = false
        // Streaming STT can still be live even after the committed-transcript
        // handler left .recording (it suspends in disconnect() before flipping
        // state), so tear it down regardless of quizState. Batch recording is
        // only ever live while .recording.
        if isStreamingSTT {
            recordingCoordinator.cleanupStreamingSTT()
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
        quizTimersController.cancelAnswerTimer()
        quizTimersController.cancelThinkingTime()

        // Stop any playing question audio immediately
        await audioDeviceState.stopAnyPlayingAudio()

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

    /// End the current quiz session
    func endQuiz() async {
        guard let sessionId = currentSession?.id else { return }

        quizTimersController.cancelAnswerTimer()
        quizTimersController.cancelAutoStopRecordingTimer()

        do {
            try await networkService.endSession(sessionId: sessionId)
            persistenceStore.clearSession()
            await audioDeviceState.stopAnyPlayingAudio() // Await properly (we're async here)
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
            await quizTimersController.startAutoAdvanceCountdown(duration: settings.autoAdvanceDelay, audioDuration: 0)
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
            quizTimersController.startThinkingTimeCountdown()
        } else {
            quizTimersController.startAnswerTimer()
        }
    }

    func handleQuizResponse(_ response: QuizResponse) async { // internal for tests; RecordingCoordinator reaches it via an injected closure
        // Guard against concurrent calls (safe: @MainActor serializes access)
        guard !isProcessingResponse else {
            Logger.quiz.warning("⚠️ handleQuizResponse already in progress, ignoring duplicate call")
            return
        }
        isProcessingResponse = true
        defer { isProcessingResponse = false }

        // Reset transcription failure counter on successful response
        recordingCoordinator.consecutiveTranscriptionFailures = 0

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
                    return await audioDeviceState.playFeedbackAudioBase64(base64)
                } else if let feedbackUrl = audioInfo.feedbackUrl {
                    return await audioDeviceState.playFeedbackAudio(from: feedbackUrl)
                }
                return 0.0
            }()

            await quizTimersController.startAutoAdvanceCountdown(duration: settings.autoAdvanceDelay, audioDuration: 0)

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
        await audioDeviceState.stopAnyPlayingAudio()

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
                await audioDeviceState.playQuestionAudio(from: questionUrl)
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
        if quizState == .askingQuestion, let audioUrl = recordingCoordinator.currentQuestionAudioUrl {
            quizTimersController.cancelAnswerTimer()
            quizTimersController.cancelThinkingTime()
            await audioDeviceState.stopAnyPlayingAudio()
            await audioDeviceState.playQuestionAudio(from: audioUrl)
        }
    }

    private func resetState() {
        // Cancel every long-lived background task in one call.
        taskBag.cancelAll()

        // Clean up streaming STT
        recordingCoordinator.cleanupStreamingSTT()

        // Stop silence detection / barge-in listening
        audioDeviceState.stopSilenceDetectionListening()

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
        currentSession = nil // also zeroes the derived score/questionsAnswered (T7)
        sessionCorrectCount = 0
        sessionIncorrectCount = 0
        errorMessage = nil
        nextQuestionAudioUrl = nil
        nextQuestion = nil
        isRerecording = false
        isAutoRecording = false
        // The two ownerless façade fields (T7) — no child owns them, so this is
        // their single explicit reset site.
        activeErrorModel = nil
        mcqVoiceMatchedKey = nil
        // Ending a quiz from the minimized widget must dismiss the widget —
        // otherwise a stale card floats over Home (#54 task 54.6).
        isMinimized = false
        // T7 unified reset model: full teardown clears every child's scoped
        // state through one reset() per child instead of scattered per-field
        // writes (paywall/mic-picker sheets + command capture + timers +
        // recording/confirmation clusters).
        entitlementReconciler.reset()
        audioDeviceState.reset()
        voiceCommandCoordinator.reset()
        quizTimersController.reset()
        recordingCoordinator.reset()
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
            viewModel.currentSession = QuizSession.preview(score: 1.0, answered: 1)
            viewModel.quizState = .showingResult(
                question: Question.preview,
                evaluation: Evaluation.previewCorrect
            )
            viewModel.settings.audioMode = AudioMode.default.id
            return viewModel
        }()
    }
#endif
