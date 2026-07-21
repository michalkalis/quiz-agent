//
//  RecordingCoordinator.swift
//  Hangs
//
//  The recording + confirmation slice extracted from QuizViewModel (#113 T5):
//  class + state + injection. Body spans RecordingCoordinator+Capture /
//  +Streaming / +Submission / +Confirmation (decision-7 ≤300-line split).
//

import Combine
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
/// `isAutoRecording`, `isRerecording`, `errorMessage`, `submissionEpoch`,
/// `mcqVoiceMatchedKey`, `isAppForeground`) stays façade-resident and is
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

    /// Consecutive transcription failures for 3-tier error escalation
    var consecutiveTranscriptionFailures: Int {
        get { recordingState.consecutiveTranscriptionFailures }
        set { recordingState.consecutiveTranscriptionFailures = newValue }
    }

    /// Current question audio URL for the "repeat" command — written by
    /// AudioDeviceState through the façade's injected closures (#113 T2,
    /// decision 4); the façade's `repeatQuestion` reads it.
    var currentQuestionAudioUrl: String? {
        get { recordingState.currentQuestionAudioUrl }
        set { recordingState.currentQuestionAudioUrl = newValue }
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

    /// Auto-confirm countdown (T7 — resides in `ConfirmationState`, its semantic
    /// owner); QuizTimersController ticks it via the façade's injected write closure.
    var autoConfirmCountdown: Int {
        get { confirmationState.autoConfirmCountdown }
        set { confirmationState.autoConfirmCountdown = newValue }
    }

    // MARK: - Dependencies (service handles + the façade's shared task owner)

    let audioService: AudioServiceProtocol
    let networkService: NetworkServiceProtocol
    let silenceDetectionService: SilenceDetectionServiceProtocol
    let sttService: ElevenLabsSTTServiceProtocol?
    let taskBag: TaskBag

    // MARK: - Injected façade closures (decision 4 — scoped reads/writes, never a vm ref)

    let settings: @MainActor () -> QuizSettings
    let quizState: @MainActor () -> QuizState
    let isAppForeground: @MainActor () -> Bool
    let currentQuestion: @MainActor () -> Question?
    let currentSession: @MainActor () -> QuizSession?
    let submissionEpoch: @MainActor () -> Int
    let isAutoRecording: @MainActor () -> Bool
    let setIsAutoRecording: @MainActor (Bool) -> Void
    let setIsRerecording: @MainActor (Bool) -> Void
    let setErrorMessage: @MainActor (String?) -> Void
    let setMcqVoiceMatchedKey: @MainActor (String?) -> Void
    private let facadeTransition: @MainActor (QuizState, String) -> Bool
    private let facadeSetError: @MainActor (String, ErrorContext, Error?) -> Void
    private let facadeHandleError: @MainActor (Error, ErrorContext, String) async -> Void
    let handleQuizResponse: @MainActor (QuizResponse) async -> Void
    let submitMCQAnswer: @MainActor (_ key: String, _ value: String) async -> Void
    let resubmitAnswer: @MainActor (_ answer: String, _ suppressAudio: Bool) async -> Void
    let skipQuestion: @MainActor () async -> Void
    let emitEarcon: @MainActor (Earcon) -> Void
    let refreshCommandWindow: @MainActor () -> Void
    let abortSkipUndoWindow: @MainActor () -> Void
    let startAutoConfirmIfEnabled: @MainActor () -> Void
    let cancelAutoConfirm: @MainActor () -> Void
    let cancelAnswerTimer: @MainActor () -> Void
    let cancelThinkingTime: @MainActor () -> Void
    let startAutoStopRecordingTimer: @MainActor () -> Void
    let cancelAutoStopRecordingTimer: @MainActor () -> Void
    let stopSilenceDetectionListening: @MainActor () -> Void

    init(
        audioService: AudioServiceProtocol,
        networkService: NetworkServiceProtocol,
        silenceDetectionService: SilenceDetectionServiceProtocol,
        sttService: ElevenLabsSTTServiceProtocol?,
        taskBag: TaskBag,
        settings: @escaping @MainActor () -> QuizSettings,
        quizState: @escaping @MainActor () -> QuizState,
        isAppForeground: @escaping @MainActor () -> Bool,
        currentQuestion: @escaping @MainActor () -> Question?,
        currentSession: @escaping @MainActor () -> QuizSession?,
        submissionEpoch: @escaping @MainActor () -> Int,
        isAutoRecording: @escaping @MainActor () -> Bool,
        setIsAutoRecording: @escaping @MainActor (Bool) -> Void,
        setIsRerecording: @escaping @MainActor (Bool) -> Void,
        setErrorMessage: @escaping @MainActor (String?) -> Void,
        setMcqVoiceMatchedKey: @escaping @MainActor (String?) -> Void,
        transition: @escaping @MainActor (QuizState, String) -> Bool,
        setError: @escaping @MainActor (String, ErrorContext, Error?) -> Void,
        handleError: @escaping @MainActor (Error, ErrorContext, String) async -> Void,
        handleQuizResponse: @escaping @MainActor (QuizResponse) async -> Void,
        submitMCQAnswer: @escaping @MainActor (_ key: String, _ value: String) async -> Void,
        resubmitAnswer: @escaping @MainActor (_ answer: String, _ suppressAudio: Bool) async -> Void,
        skipQuestion: @escaping @MainActor () async -> Void,
        emitEarcon: @escaping @MainActor (Earcon) -> Void,
        refreshCommandWindow: @escaping @MainActor () -> Void,
        abortSkipUndoWindow: @escaping @MainActor () -> Void,
        startAutoConfirmIfEnabled: @escaping @MainActor () -> Void,
        cancelAutoConfirm: @escaping @MainActor () -> Void,
        cancelAnswerTimer: @escaping @MainActor () -> Void,
        cancelThinkingTime: @escaping @MainActor () -> Void,
        startAutoStopRecordingTimer: @escaping @MainActor () -> Void,
        cancelAutoStopRecordingTimer: @escaping @MainActor () -> Void,
        stopSilenceDetectionListening: @escaping @MainActor () -> Void
    ) {
        self.audioService = audioService
        self.networkService = networkService
        self.silenceDetectionService = silenceDetectionService
        self.sttService = sttService
        self.taskBag = taskBag
        self.settings = settings
        self.quizState = quizState
        self.isAppForeground = isAppForeground
        self.currentQuestion = currentQuestion
        self.currentSession = currentSession
        self.submissionEpoch = submissionEpoch
        self.isAutoRecording = isAutoRecording
        self.setIsAutoRecording = setIsAutoRecording
        self.setIsRerecording = setIsRerecording
        self.setErrorMessage = setErrorMessage
        self.setMcqVoiceMatchedKey = setMcqVoiceMatchedKey
        facadeTransition = transition
        facadeSetError = setError
        facadeHandleError = handleError
        self.handleQuizResponse = handleQuizResponse
        self.submitMCQAnswer = submitMCQAnswer
        self.resubmitAnswer = resubmitAnswer
        self.skipQuestion = skipQuestion
        self.emitEarcon = emitEarcon
        self.refreshCommandWindow = refreshCommandWindow
        self.abortSkipUndoWindow = abortSkipUndoWindow
        self.startAutoConfirmIfEnabled = startAutoConfirmIfEnabled
        self.cancelAutoConfirm = cancelAutoConfirm
        self.cancelAnswerTimer = cancelAnswerTimer
        self.cancelThinkingTime = cancelThinkingTime
        self.startAutoStopRecordingTimer = startAutoStopRecordingTimer
        self.cancelAutoStopRecordingTimer = cancelAutoStopRecordingTimer
        self.stopSilenceDetectionListening = stopSilenceDetectionListening
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
        // Streaming teardown first: a reset can fire while the engine is still
        // capturing; zeroing `isStreamingSTT` without stopping it would leak a
        // live recorder past cleanupStreamingSTT's guard.
        cleanupStreamingSTT()
        recordingState.reset()
        confirmationState.reset()
    }

    /// Decision-8 phase-exit reset: invoked by the façade's `transition(to:)`
    /// when the quiz leaves the recording/processing pair. Drops the
    /// confirmation subset + capture-scoped recording state; question-scoped
    /// fields survive — `consecutiveTranscriptionFailures` accumulates across
    /// its own tier-1/2 bail-out transitions out of the pair (else the 3-tier
    /// escalation could never fire) and `currentQuestionAudioUrl` is replayed
    /// from `.showingResult` ("read aloud" / voice "repeat").
    func resetOnPhaseExit() {
        cleanupStreamingSTT()
        recordingState.resetCaptureState()
        confirmationState.reset()
    }

    // MARK: - Cleanup Choke Points (also called cross-cluster by the façade)

    /// Cancel silence detection subscription
    func cancelSilenceDetection() {
        taskBag.cancel(.silenceDetection)
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
