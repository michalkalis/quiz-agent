//
//  RecordingCoordinator.swift
//  Hangs
//
//  The recording + confirmation slice extracted from QuizViewModel (#113 T5):
//  class + state + injection. Body spans RecordingCoordinator+Capture /
//  +Streaming / +Submission / +Confirmation (decision-7 ≤300-line split).
//

import Combine
import Clocks
import Foundation
import os

/// The recording + confirmation slice as its own child object (#113 T5). The
/// façade (QuizViewModel) owns this child, re-publishes its `objectWillChange`,
/// and re-exposes the view-facing slice via permanent forwarding accessors
/// (decision 2) — views never bind it directly. The recording and confirmation
/// clusters live in the private `RecordingState`/`ConfirmationState` sub-structs
/// (S6b, decision 8 — see `QuizState+PhaseState.swift`); the same-file accessors
/// below are the only doors, shared by the decision-7 extension files, the
/// façade forwards, and tests. Cross-cluster state (`quizState`, `settings`,
/// `isAutoRecording`, `isRerecording`, `errorMessage`, `mcqVoiceMatchedKey`,
/// `isAppForeground`) stays façade-resident and is
/// reached ONLY through the injected closures below (decision 4 — a child
/// never holds a back-pointer to the view model).
@MainActor
final class RecordingCoordinator: ObservableObject {
    // MARK: - Clustered phase state (#113 T7, decision 8)

    /// Recording-cluster subset — dropped atomically by `reset()`.
    @Published private var recordingState = RecordingState()

    /// Confirmation-cluster subset (incl. `autoConfirmCountdown`) — dropped
    /// atomically by `reset()`.
    @Published private var confirmationState = ConfirmationState()

    // MARK: - Recording-cluster accessors

    /// Live transcript from ElevenLabs (updates as user speaks)
    var liveTranscript: String {
        get { recordingState.liveTranscript }
        set { recordingState.liveTranscript = newValue }
    }

    /// Whether streaming STT is active
    var isStreamingSTT: Bool {
        get { recordingState.isStreamingSTT }
        set { recordingState.isStreamingSTT = newValue }
    }

    /// Whether speech has been detected during auto-record (for UI hints)
    var speechDetectedDuringAutoRecord: Bool {
        get { recordingState.speechDetectedDuringAutoRecord }
        set { recordingState.speechDetectedDuringAutoRecord = newValue }
    }

    /// Prevents concurrent stopRecordingAndSubmit calls (silence detection + user tap can race)
    var isStoppingRecording: Bool {
        get { recordingState.isStoppingRecording }
        set { recordingState.isStoppingRecording = newValue }
    }

    /// See `RecordingState.emptyAnswerRetryHintQuestionKey` (#185 track B).
    var emptyAnswerRetryHintQuestionKey: String? {
        get { recordingState.emptyAnswerRetryHintQuestionKey }
        set { recordingState.emptyAnswerRetryHintQuestionKey = newValue }
    }

    /// See `RecordingState.emptyAnswerRetryPrompt` (#185 track G).
    var emptyAnswerRetryPrompt: SpokenPrompt {
        get { recordingState.emptyAnswerRetryPrompt }
        set { recordingState.emptyAnswerRetryPrompt = newValue }
    }

    /// See `RecordingState.backgroundSuppressedRecordingAt` (#171 Track H).
    var backgroundSuppressedRecordingAt: AnyClock<Duration>.Instant? {
        get { recordingState.backgroundSuppressedRecordingAt }
        set { recordingState.backgroundSuppressedRecordingAt = newValue }
    }

    /// Current question audio URL for the "repeat" command — written by
    /// AudioDeviceState through the façade's injected closures (#113 T2,
    /// decision 4); the façade's `repeatQuestion` reads it.
    var currentQuestionAudioUrl: String? {
        get { recordingState.currentQuestionAudioUrl }
        set { recordingState.currentQuestionAudioUrl = newValue }
    }

    /// See `RecordingState.emptyAnswerRetryQuestionKey` (#185 track B).
    var emptyAnswerRetryQuestionKey: String? {
        get { recordingState.emptyAnswerRetryQuestionKey }
        set { recordingState.emptyAnswerRetryQuestionKey = newValue }
    }

    // MARK: - Confirmation-cluster accessors

    /// Answer confirmation modal visibility (QuestionView sheet binding via façade forward)
    var showAnswerConfirmation: Bool {
        get { confirmationState.showAnswerConfirmation }
        set { confirmationState.showAnswerConfirmation = newValue }
    }

    /// The transcribed answer shown/edited in the confirmation modal
    var transcribedAnswer: String {
        get { confirmationState.transcribedAnswer }
        set { confirmationState.transcribedAnswer = newValue }
    }

    /// Pending Whisper response awaiting user confirmation
    var pendingResponse: QuizResponse? {
        get { confirmationState.pendingResponse }
        set { confirmationState.pendingResponse = newValue }
    }

    /// Suppress TTS on edited confirmations
    var transcriptWasEdited: Bool {
        get { confirmationState.transcriptWasEdited }
        set { confirmationState.transcriptWasEdited = newValue }
    }

    /// Snapshot for cancelEditingTranscript()
    var preEditTranscript: String? {
        get { confirmationState.preEditTranscript }
        set { confirmationState.preEditTranscript = newValue }
    }

    /// See `ConfirmationState.noAnswerCaptured` (#171 Track B).
    var noAnswerCaptured: Bool {
        get { confirmationState.noAnswerCaptured }
        set { confirmationState.noAnswerCaptured = newValue }
    }

    /// See `ConfirmationState.owner` (#186 step 1).
    var confirmationOwner: AttemptID? {
        get { confirmationState.owner }
        set { confirmationState.owner = newValue }
    }

    /// See `ConfirmationState.isEvaluatingAnswer` (#173 C2).
    var isEvaluatingAnswer: Bool {
        get { confirmationState.isEvaluatingAnswer }
        set { confirmationState.isEvaluatingAnswer = newValue }
    }

    /// Auto-confirm countdown (T7 — resides in `ConfirmationState`, its semantic
    /// owner); QuizTimersController ticks it via the façade's injected write closure.
    var autoConfirmCountdown: Int {
        get { confirmationState.autoConfirmCountdown }
        set { confirmationState.autoConfirmCountdown = newValue }
    }

    /// See `ConfirmationState.countdownHold` (#185).
    var countdownHold: ConfirmationCountdownHold? {
        get { confirmationState.countdownHold }
        set { confirmationState.countdownHold = newValue }
    }

    /// See `ConfirmationState.spokenReplacement` (#185 5.1).
    var spokenReplacement: SpokenReplacement? {
        get { confirmationState.spokenReplacement }
        set { confirmationState.spokenReplacement = newValue }
    }

    // MARK: - Dependencies (service handles + the façade's shared task owner)

    let audioService: AudioServiceProtocol
    let networkService: NetworkServiceProtocol
    let silenceDetectionService: SilenceDetectionServiceProtocol
    let sttService: ElevenLabsSTTServiceProtocol?
    let taskBag: TaskBag
    /// #186 step 1: the façade's attempt owner, shared like `taskBag` — every
    /// async result in this coordinator proves ownership through it.
    let attemptLedger: AttemptLedger

    /// The façade's clock (#180 track A): submit timeout, cold-wake backoff and
    /// the STT commit watchdog all run on it.
    let clock: AnyClock<Duration>

    // MARK: - #184 batch answer capture

    /// The PCM accumulator the listener engine's tap tees into while a batch
    /// answer is being recorded (#184 track B). One per coordinator; `begin` /
    /// `finish` bracket each recording.
    let answerCapture = AnswerCapture()

    /// #185 track F: the live mic level the question screen's listen bar
    /// breathes with. Its own observable so a ~47 Hz level never re-renders
    /// the whole screen (see `RecordingInputLevel`).
    let inputLevel = RecordingInputLevel()

    /// Whether THIS recording started the shared mic engine itself (voice
    /// commands off → nobody else had armed it). Only then does the recording
    /// stop it again — otherwise the command window owns the engine's lifetime.
    var startedListenerForAnswer = false

    /// Stamp of the saved car sample for this recording, so the transcript can
    /// be attached to its sidecar once the backend answers. `nil` = not saved.
    var savedRecordingStamp: String?

    /// #184 track D: a read-back of the recognised answer is playing on the
    /// confirmation sheet (see RecordingCoordinator+ReadBack).
    var isReadingBackAnswer = false

    /// #185 track B: the "didn't catch that" prompt before the automatic
    /// re-record is playing (see RecordingCoordinator+EmptyAnswer).
    var isSpeakingRetryPrompt = false

    /// #185 5.1: the listener's audio is being kept while the answer sheet is
    /// up, so a new spoken answer can be transcribed without saying it twice
    /// (see RecordingCoordinator+SpokenAnswer).
    var isSheetCaptureActive = false

    /// This recording runs on the plain `AVAudioRecorder` because the shared
    /// mic engine could not come up (recognizer setup failed). No voice
    /// processing, no VAD — the dead-air cap ends it — but the mic button works.
    var usesLegacyRecorder = false

    /// #185 track A: why the 5 s no-speech window did NOT end this recording
    /// (the detector could not vouch for the silence), or `nil`. Telemetry
    /// only — logged with the recording's stop.
    var noSpeechWindowDeferral: NoSpeechWindowVerdict?

    /// #184: whether the NEXT recording takes the ElevenLabs Realtime path
    /// (`sttService` present AND the runtime switch on). The façade injects the
    /// production read (`VoicePipelineFlags.realtimeSTTEnabled`); tests default
    /// to `true` so an injected mock STT service still means "streaming".
    let realtimeSTTEnabled: @MainActor () -> Bool

    // MARK: - Injected façade closures (decision 4 — scoped reads/writes, never a vm ref)

    let settings: @MainActor () -> QuizSettings
    let quizState: @MainActor () -> QuizState
    let isAppForeground: @MainActor () -> Bool
    let currentQuestion: @MainActor () -> Question?
    let currentSession: @MainActor () -> QuizSession?
    let isAutoRecording: @MainActor () -> Bool
    let setIsAutoRecording: @MainActor (Bool) -> Void
    let setIsRerecording: @MainActor (Bool) -> Void
    let setErrorMessage: @MainActor (String?) -> Void
    let setMcqVoiceMatchedKey: @MainActor (String?) -> Void
    private let facadeTransition: @MainActor (QuizState, String) -> Bool
    private let facadeSetError: @MainActor (String, ErrorContext, Error?) -> Void
    private let facadeHandleError: @MainActor (Error, ErrorContext, String) async -> Void
    /// The response plus the attempt that submitted it (#186 step 1).
    let handleQuizResponse: @MainActor (QuizResponse, AttemptID) async -> Void
    let resubmitAnswer: @MainActor (_ answer: String, _ suppressAudio: Bool) async -> Void
    let skipQuestion: @MainActor () async -> Void
    let emitEarcon: @MainActor (Earcon) -> Void
    let refreshCommandWindow: @MainActor () -> Void
    /// #185 5.2: bring the command window up and report whether the listener
    /// is live — the auto-confirm countdown waits for it.
    let armCommandWindow: @MainActor () async -> Bool
    let abortSkipUndoWindow: @MainActor () -> Void
    let startAutoConfirmIfEnabled: @MainActor () -> Void
    let cancelAutoConfirm: @MainActor () -> Void
    /// #171 Track D: drop the quiz-level pause. Leaving the sheet by ANY
    /// route resumes — confirming, re-recording and cancelling all move the
    /// quiz on, and a stale flag would then mute the result screen's
    /// auto-advance and the NEXT question's auto-confirm.
    let clearPause: @MainActor () -> Void
    let cancelAnswerTimer: @MainActor () -> Void
    let cancelThinkingTime: @MainActor () -> Void
    /// Test seam (#173): the two window lengths this coordinator arms —
    /// `speechStartWindow` is the visible "time to start speaking",
    /// `deadAirCap` is the hidden cap under it. Production never assigns them;
    /// they exist so unit tests can exercise arming and expiry without spending
    /// real wall-clock seconds, which on a loaded CI runner elapsed mid-test and
    /// reopened the empty-answer sheet under assertions about the mic being
    /// open. BOTH deadlines go through the seam — a cap that quietly kept the
    /// production 15 s made "park the window" a lie and was exactly that CI
    /// failure.
    var speechStartWindow: TimeInterval = Config.speechStartWindow
    var deadAirCap: TimeInterval = Config.autoRecordingDuration

    let startAutoStopRecordingTimer: @MainActor (_ duration: TimeInterval, _ hardCap: TimeInterval) -> Void
    /// Arm the hidden dead-air cap alone, for the stretch between asking for the
    /// mic and the engine actually coming up — there is no honest countdown to
    /// show yet, but a recording still may not be left without a deadline.
    let armRecordingDeadAirCap: @MainActor (TimeInterval) -> Void
    let cancelAutoStopRecordingTimer: @MainActor () -> Void
    /// #173: first proof the driver is speaking — hides the visible "time to
    /// start speaking" countdown (the hidden dead-air cap keeps running).
    let onSpeechStarted: @MainActor () -> Void
    let stopSilenceDetectionListening: @MainActor () -> Void
    /// #184 track D: the answer read-back is app TTS — while it plays the
    /// command window must stay closed (`isPlayingAnyTTS`) and mute must win.
    let isMuted: @MainActor () -> Bool
    let setPlayingAnswerReadBack: @MainActor (Bool) -> Void
    /// #185 (founder 2026-09-24): the question read-out is playing — a manual
    /// start interrupts it, the hands-free start waits for it (see +Trigger).
    let isPlayingQuestionTTS: @MainActor () -> Bool
    /// Stop the question read-out (initial read or a replay) so the mic can open.
    let stopQuestionReadOut: @MainActor () async -> Void

    init(
        audioService: AudioServiceProtocol,
        networkService: NetworkServiceProtocol,
        silenceDetectionService: SilenceDetectionServiceProtocol,
        sttService: ElevenLabsSTTServiceProtocol?,
        taskBag: TaskBag,
        attemptLedger: AttemptLedger,
        clock: AnyClock<Duration>,
        settings: @escaping @MainActor () -> QuizSettings,
        quizState: @escaping @MainActor () -> QuizState,
        isAppForeground: @escaping @MainActor () -> Bool,
        currentQuestion: @escaping @MainActor () -> Question?,
        currentSession: @escaping @MainActor () -> QuizSession?,
        isAutoRecording: @escaping @MainActor () -> Bool,
        setIsAutoRecording: @escaping @MainActor (Bool) -> Void,
        setIsRerecording: @escaping @MainActor (Bool) -> Void,
        setErrorMessage: @escaping @MainActor (String?) -> Void,
        setMcqVoiceMatchedKey: @escaping @MainActor (String?) -> Void,
        transition: @escaping @MainActor (QuizState, String) -> Bool,
        setError: @escaping @MainActor (String, ErrorContext, Error?) -> Void,
        handleError: @escaping @MainActor (Error, ErrorContext, String) async -> Void,
        handleQuizResponse: @escaping @MainActor (QuizResponse, AttemptID) async -> Void,
        resubmitAnswer: @escaping @MainActor (_ answer: String, _ suppressAudio: Bool) async -> Void,
        skipQuestion: @escaping @MainActor () async -> Void,
        emitEarcon: @escaping @MainActor (Earcon) -> Void,
        refreshCommandWindow: @escaping @MainActor () -> Void,
        armCommandWindow: @escaping @MainActor () async -> Bool,
        abortSkipUndoWindow: @escaping @MainActor () -> Void,
        startAutoConfirmIfEnabled: @escaping @MainActor () -> Void,
        cancelAutoConfirm: @escaping @MainActor () -> Void,
        clearPause: @escaping @MainActor () -> Void,
        cancelAnswerTimer: @escaping @MainActor () -> Void,
        cancelThinkingTime: @escaping @MainActor () -> Void,
        startAutoStopRecordingTimer: @escaping @MainActor (TimeInterval, TimeInterval) -> Void,
        armRecordingDeadAirCap: @escaping @MainActor (TimeInterval) -> Void,
        cancelAutoStopRecordingTimer: @escaping @MainActor () -> Void,
        onSpeechStarted: @escaping @MainActor () -> Void,
        stopSilenceDetectionListening: @escaping @MainActor () -> Void,
        isMuted: @escaping @MainActor () -> Bool = { false },
        setPlayingAnswerReadBack: @escaping @MainActor (Bool) -> Void = { _ in },
        isPlayingQuestionTTS: @escaping @MainActor () -> Bool = { false },
        stopQuestionReadOut: @escaping @MainActor () async -> Void = {},
        realtimeSTTEnabled: @escaping @MainActor () -> Bool = { true }
    ) {
        self.audioService = audioService
        self.networkService = networkService
        self.silenceDetectionService = silenceDetectionService
        self.sttService = sttService
        self.taskBag = taskBag
        self.attemptLedger = attemptLedger
        self.clock = clock
        self.settings = settings
        self.quizState = quizState
        self.isAppForeground = isAppForeground
        self.currentQuestion = currentQuestion
        self.currentSession = currentSession
        self.isAutoRecording = isAutoRecording
        self.setIsAutoRecording = setIsAutoRecording
        self.setIsRerecording = setIsRerecording
        self.setErrorMessage = setErrorMessage
        self.setMcqVoiceMatchedKey = setMcqVoiceMatchedKey
        facadeTransition = transition
        facadeSetError = setError
        facadeHandleError = handleError
        self.handleQuizResponse = handleQuizResponse
        self.resubmitAnswer = resubmitAnswer
        self.skipQuestion = skipQuestion
        self.emitEarcon = emitEarcon
        self.refreshCommandWindow = refreshCommandWindow
        self.armCommandWindow = armCommandWindow
        self.abortSkipUndoWindow = abortSkipUndoWindow
        self.startAutoConfirmIfEnabled = startAutoConfirmIfEnabled
        self.cancelAutoConfirm = cancelAutoConfirm
        self.clearPause = clearPause
        self.cancelAnswerTimer = cancelAnswerTimer
        self.cancelThinkingTime = cancelThinkingTime
        self.startAutoStopRecordingTimer = startAutoStopRecordingTimer
        self.armRecordingDeadAirCap = armRecordingDeadAirCap
        self.cancelAutoStopRecordingTimer = cancelAutoStopRecordingTimer
        self.onSpeechStarted = onSpeechStarted
        self.stopSilenceDetectionListening = stopSilenceDetectionListening
        self.isMuted = isMuted
        self.setPlayingAnswerReadBack = setPlayingAnswerReadBack
        self.isPlayingQuestionTTS = isPlayingQuestionTTS
        self.stopQuestionReadOut = stopQuestionReadOut
        self.realtimeSTTEnabled = realtimeSTTEnabled
    }

    // MARK: - Façade fan-out wrappers (keep the moved call sites byte-identical)

    /// Validated façade state transition — see `QuizViewModel.transition(to:caller:)`.
    /// The default `#function` expands at the call site, so the façade's
    /// transition log keeps the real caller name.
    @discardableResult
    func transition(to newState: QuizState, caller: String = #function) -> Bool {
        facadeTransition(newState, caller)
    }

    /// See `QuizViewModel.setError(message:context:error:model:)`.
    func setError(message: String, context: ErrorContext, error: Error? = nil) {
        facadeSetError(message, context, error)
    }

    /// See `QuizViewModel.handleError(_:context:fallbackMessage:)`.
    func handleError(_ error: Error, context: ErrorContext, fallbackMessage: String) async {
        await facadeHandleError(error, context, fallbackMessage)
    }

    /// T7 unified reset model, full teardown: drops both phase-state subsets
    /// atomically, question-scoped fields included. Invoked by the façade's
    /// `resetState`. Long-lived task teardown stays with the façade's
    /// `taskBag.cancelAll()`.
    func reset() {
        // #184: the read-back task may have been cancelled by the façade's
        // `taskBag.cancelAll()` at its early-return exits, which never clear the
        // flags — a latched `isPlayingAnswerReadBack` would keep the command
        // window closed for the rest of the session. Idempotent.
        cancelAnswerReadBack()
        cancelRetryPrompt() // #185 — same latch hazard as the read-back
        stopSheetCapture() // #185 5.1 — before the capture it shares is abandoned
        abandonAnswerCapture()
        inputLevel.reset() // #185 track F — the façade's cancelAll ended its feed
        // Streaming teardown first: a reset can fire while the engine is still
        // capturing; zeroing `isStreamingSTT` without stopping it would leak a
        // live recorder past cleanupStreamingSTT's guard.
        cleanupStreamingSTT()
        recordingState.reset()
        confirmationState.reset()
    }

    /// Decision-8 phase-exit reset: invoked by the façade's `transition(to:)`
    /// when the quiz leaves the recording/processing pair. Drops the
    /// confirmation subset + capture-scoped recording state; the question-scoped
    /// `currentQuestionAudioUrl` survives — it is replayed from
    /// `.showingResult` ("read aloud" / voice "repeat").
    func resetOnPhaseExit() {
        cancelAnswerReadBack() // #184 — see reset()
        stopSheetCapture() // #185 5.1: the sheet it listened for is gone
        cleanupStreamingSTT()
        recordingState.resetCaptureState()
        confirmationState.reset()
    }

    // MARK: - Cleanup Choke Points (also called cross-cluster by the façade)

    /// Cancel silence detection subscription
    func cancelSilenceDetection() {
        taskBag.cancel(.silenceDetection)
        // #185 track F: the level feed shares the VAD's lifetime — both end
        // when the recording does, and the bar must stop glowing with them.
        taskBag.cancel(.inputLevel)
        inputLevel.reset()
    }

    /// Clean up streaming STT resources
    func cleanupStreamingSTT() {
        taskBag.cancel(.sttEvent)
        taskBag.cancel(.sttChunk)
        if isStreamingSTT {
            audioService.stopStreamingRecording()
            Task { [sttService] in await sttService?.disconnect() }
            isStreamingSTT = false
            liveTranscript = ""
        }
    }
}
