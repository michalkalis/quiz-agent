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
/// clusters live here as child-owned fields (they fold into `RecordingState`/
/// `ConfirmationState` sub-structs in S6b, decision 8; internal rather than
/// private only because the decision-7 file split puts their accessors in
/// same-type extension files). Cross-cluster state (`quizState`, `settings`,
/// `isAutoRecording`, `isRerecording`, `errorMessage`, `submissionEpoch`,
/// `mcqVoiceMatchedKey`, `isAppForeground`) stays façade-resident and is
/// reached ONLY through the injected closures below (decision 4 — a child
/// never holds a back-pointer to the view model).
@MainActor
final class RecordingCoordinator: ObservableObject {
    // MARK: - Recording-cluster state

    /// Live transcript from ElevenLabs (updates as user speaks)
    @Published var liveTranscript: String = ""

    /// Whether streaming STT is active
    @Published var isStreamingSTT: Bool = false

    /// Whether speech has been detected during auto-record (for UI hints)
    @Published var speechDetectedDuringAutoRecord: Bool = false

    /// Prevents concurrent stopRecordingAndSubmit calls (silence detection + user tap can race)
    var isStoppingRecording = false

    /// Consecutive transcription failures for 3-tier error escalation
    var consecutiveTranscriptionFailures: Int = 0

    /// Current question audio URL for the "repeat" command — written by
    /// AudioDeviceState through the façade's injected closures (#113 T2,
    /// decision 4); the façade's `repeatQuestion`/`resetState` read/clear it.
    var currentQuestionAudioUrl: String?

    // MARK: - Confirmation-cluster state

    /// Answer confirmation modal visibility (QuestionView sheet binding via façade forward)
    @Published var showAnswerConfirmation = false

    /// The transcribed answer shown/edited in the confirmation modal
    @Published var transcribedAnswer = ""

    /// Pending Whisper response awaiting user confirmation
    var pendingResponse: QuizResponse? = nil

    /// Suppress TTS on edited confirmations
    var transcriptWasEdited = false

    /// Snapshot for cancelEditingTranscript()
    var preEditTranscript: String? = nil

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

    /// T7 unified reset model: clears this child's own scoped state (both
    /// clusters); task teardown stays with the façade's `taskBag.cancelAll()`.
    /// Not yet wired — the façade's `resetState`/`transition` invokes this
    /// once T7 (S6b) lands.
    func reset() {
        liveTranscript = ""
        isStreamingSTT = false
        speechDetectedDuringAutoRecord = false
        isStoppingRecording = false
        consecutiveTranscriptionFailures = 0
        currentQuestionAudioUrl = nil
        showAnswerConfirmation = false
        transcribedAnswer = ""
        pendingResponse = nil
        transcriptWasEdited = false
        preEditTranscript = nil
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
