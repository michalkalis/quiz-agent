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

import Clocks
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

    /// #185 track B (founder 2026-09-24): the "didn't catch your answer" line is
    /// on screen for this question (`questionId ?? ""`) from the automatic retry
    /// until its recording stops. Keyed by question so a retry abandoned by a
    /// skip can never show on the next one.
    var emptyAnswerRetryHintQuestionKey: String?

    /// #171 Track H: when `startRecording()` was suppressed because the app was
    /// backgrounded (the think/answer countdown kept running and expired out of
    /// sight). Foregrounding reads it to do what should have happened — open the
    /// mic if the answer window still has time, otherwise hand over to the
    /// no-answer confirmation sheet.
    var backgroundSuppressedRecordingAt: AnyClock<Duration>.Instant?

    // Question-scoped — must SURVIVE pair exits (only full `reset()` clears
    // it): the audio URL is replayed from .showingResult.

    /// Current question audio URL for "read aloud" / the "repeat" command —
    /// written by AudioDeviceState through the façade's injected closures
    /// (#113 T2, decision 4).
    var currentQuestionAudioUrl: String?

    /// #185 track B (founder 1.1): the question whose one automatic re-record
    /// after an empty answer has been spent (`questionId ?? ""`). Question-scoped
    /// on purpose — the retry itself leaves the recording/processing pair, and
    /// the SECOND miss must still find the budget used and open the sheet.
    var emptyAnswerRetryQuestionKey: String?

    /// Drop only the capture-scoped subset (phase exit, decision 8).
    mutating func resetCaptureState() {
        liveTranscript = ""
        isStreamingSTT = false
        speechDetectedDuringAutoRecord = false
        isStoppingRecording = false
        backgroundSuppressedRecordingAt = nil
        emptyAnswerRetryHintQuestionKey = nil
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

    /// #171 Track B: the sheet is showing an EMPTY field on purpose — nothing
    /// was captured — rather than waiting for a transcript to arrive. Without
    /// this the presenter cannot tell the two empty-transcript cases apart and
    /// renders the "Transcribing…" spinner over the no-answer sheet.
    var noAnswerCaptured: Bool = false

    /// #173 (founder decision C2): the answer has been confirmed and is being
    /// evaluated, and the sheet STAYS UP while it is — its primary button
    /// becomes the spinner ("Vyhodnocujem…") and every other control on it goes
    /// dead. Separate from `showAnswerConfirmation`, which `confirmAnswer()`
    /// clears synchronously as its single-flight token: that guarantee must not
    /// change just so the sheet can linger.
    var isEvaluatingAnswer: Bool = false

    /// #186 step 1: the attempt this sheet was opened for. Checked by the
    /// invariants (a sheet always belongs to the CURRENT attempt) and handed to
    /// `handleQuizResponse` on confirm, so a sheet that somehow outlived its
    /// attempt can never grade into the next one. `nil` only for DEBUG seeds.
    var owner: AttemptID?

    /// Auto-confirm countdown — confirmation-semantic, so it lives here (its
    /// semantic owner, T7); QuizTimersController only ticks it through the
    /// façade's injected write closure (decision 4), never owning it.
    var autoConfirmCountdown: Int = 0

    /// Drop the whole subset atomically (T7 unified reset model).
    mutating func reset() { self = ConfirmationState() }
}
