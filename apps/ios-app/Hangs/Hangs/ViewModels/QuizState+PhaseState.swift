//
//  QuizState+PhaseState.swift
//  Hangs
//
//  Phase-scoped state sub-structs (#113 T7, decision 8): the recording and
//  confirmation clusters folded into value types held as private @Published
//  fields inside RecordingCoordinator, so leaving the recording/processing
//  phase-pair drops each subset atomically via one reset() instead of the
//  pre-#113 scattered per-field writes.
//

import Foundation

/// Recording-cluster phase state — owned privately by `RecordingCoordinator`;
/// reached only through its same-file accessors.
struct RecordingState {
    // Capture-scoped — dropped whenever the quiz leaves the
    // recording/processing pair (`resetCaptureState`).

    /// Live transcript from ElevenLabs (updates as user speaks)
    var liveTranscript: String = ""

    /// Whether streaming STT is active
    var isStreamingSTT: Bool = false

    /// Whether speech has been detected during auto-record (for UI hints)
    var speechDetectedDuringAutoRecord: Bool = false

    /// Prevents concurrent stopRecordingAndSubmit calls (silence detection + user tap can race)
    var isStoppingRecording: Bool = false

    // Question-scoped — must SURVIVE pair exits (only full `reset()` clears
    // them): the escalation counter accumulates across its own tier-1/2
    // bail-out transitions, and the audio URL is replayed from .showingResult.

    /// Consecutive transcription failures for 3-tier error escalation
    var consecutiveTranscriptionFailures: Int = 0

    /// Current question audio URL for "read aloud" / the "repeat" command —
    /// written by AudioDeviceState through the façade's injected closures
    /// (#113 T2, decision 4).
    var currentQuestionAudioUrl: String?

    /// Drop only the capture-scoped subset (phase exit, decision 8).
    mutating func resetCaptureState() {
        liveTranscript = ""
        isStreamingSTT = false
        speechDetectedDuringAutoRecord = false
        isStoppingRecording = false
    }

    /// Drop the whole subset atomically (full teardown, T7 unified reset model).
    mutating func reset() { self = RecordingState() }
}

/// Confirmation-cluster phase state — owned privately by `RecordingCoordinator`;
/// reached only through its same-file accessors.
struct ConfirmationState {
    /// Answer confirmation modal visibility (QuestionView sheet binding via façade forward)
    var showAnswerConfirmation: Bool = false

    /// The transcribed answer shown/edited in the confirmation modal
    var transcribedAnswer: String = ""

    /// Pending Whisper response awaiting user confirmation
    var pendingResponse: QuizResponse?

    /// Suppress TTS on edited confirmations
    var transcriptWasEdited: Bool = false

    /// Snapshot for cancelEditingTranscript()
    var preEditTranscript: String?

    /// Auto-confirm countdown — confirmation-semantic, so it lives here (its
    /// semantic owner, T7); QuizTimersController only ticks it through the
    /// façade's injected write closure (decision 4), never owning it.
    var autoConfirmCountdown: Int = 0

    /// Drop the whole subset atomically (T7 unified reset model).
    mutating func reset() { self = ConfirmationState() }
}
