//
//  RecordingCoordinator+Confirmation.swift
//  Hangs
//
//  Answer confirmation (#113 T5): confirm / edit / re-record / cancel over the
//  confirmation-cluster state (the `ConfirmationState` sub-struct lands in S6b).
//

import Foundation
import os

// MARK: - Answer Confirmation

extension RecordingCoordinator {
    /// Confirm the transcribed answer and proceed to show result
    func confirmAnswer() async {
        cancelAutoConfirm()
        showAnswerConfirmation = false

        let silent = transcriptWasEdited
        transcriptWasEdited = false
        preEditTranscript = nil

        // #100.2 capture-then-clear on ENTRY (before any await, both paths):
        // a concurrent or stray-late second call must find pendingResponse AND
        // transcribedAnswer already consumed. Clearing only in the streaming
        // tail left the Whisper path open — the first call consumes
        // pendingResponse and suspends in handleQuizResponse; the second falls
        // through to the streaming tail, still sees the stale transcript, and
        // resubmits it against whatever question is current by then.
        let answer = transcribedAnswer
        transcribedAnswer = ""

        // If we have a pending Whisper response, use it directly
        if let response = pendingResponse {
            pendingResponse = nil
            await handleQuizResponse(response)
            return
        }

        // Streaming STT path: submit the transcribed text via /sessions/{id}/input
        guard !answer.isEmpty else { return }
        await resubmitAnswer(answer, silent)
    }

    /// User tapped the pencil to edit the transcribed answer. Cancels the
    /// auto-confirm countdown and invalidates any cached Whisper evaluation so
    /// `confirmAnswer()` re-evaluates the edited text via the streaming path
    /// with TTS suppressed (edits are silent — we assume the user is typing
    /// rather than driving at that moment).
    ///
    /// Snapshots `transcribedAnswer` so `cancelEditingTranscript()` can
    /// restore it if the user backs out of the edit.
    func beginEditingTranscript() {
        cancelAutoConfirm()
        pendingResponse = nil
        transcriptWasEdited = true
        preEditTranscript = transcribedAnswer
    }

    /// User tapped Cancel inside the edit branch of the confirmation sheet.
    /// Restore the pre-edit transcript so the read-only view shows the
    /// original recognized text, clear the edit flag, and leave the sheet
    /// up — no state-machine transition. The view layer dismisses the
    /// keyboard and flips back to the read-only branch on its own.
    func cancelEditingTranscript() {
        guard let snapshot = preEditTranscript else { return }
        transcribedAnswer = snapshot
        preEditTranscript = nil
        transcriptWasEdited = false
    }

    /// Defense-in-depth cleanup if the answer confirmation sheet is dismissed
    /// without Confirm or Re-record (e.g., programmatic dismiss, future changes).
    /// No-op when pendingResponse was already consumed by confirmAnswer/rerecordAnswer.
    func handleAnswerConfirmationDismissed() {
        guard pendingResponse != nil else { return }
        pendingResponse = nil
        transcriptWasEdited = false
        preEditTranscript = nil
        transition(to: .askingQuestion)
        setErrorMessage(nil)
    }

    /// Reject the transcribed answer and start a new recording attempt immediately
    /// (#108A — founder-confirmed: no intermediate countdown, mirrors the manual
    /// mic button's `.askingQuestion` → `.recording` path in `toggleRecording()`).
    /// `isRerecording` stays set so the brief `.askingQuestion` bridge state
    /// below can't be hijacked by a stale in-flight TTS-completion callback
    /// starting its own auto-record/thinking-time countdown on top of this one.
    func rerecordAnswer() {
        // Single-flight: the sheet is only up while .processing; the first call
        // synchronously flips to .askingQuestion, so a double-tap or a tap racing
        // the "again" voice command becomes a no-op instead of spawning a second
        // startRecording() Task (two-engine crash class, #64/#77).
        guard quizState() == .processing else { return }
        cancelAutoConfirm()
        showAnswerConfirmation = false
        pendingResponse = nil
        transcriptWasEdited = false
        preEditTranscript = nil
        setIsRerecording(true)
        cancelAnswerTimer()
        cancelThinkingTime()
        transition(to: .askingQuestion) // Transient bridge state before recording starts
        setErrorMessage(nil)
        Task { [weak self] in
            await self?.startRecording()
        }
    }

    /// Cancel the processing operation and return to question state
    func cancelProcessing() {
        cancelAutoConfirm()
        taskBag.cancel(.voiceSubmission)
        taskBag.cancel(.sttCommitWatchdog)
        cancelAnswerTimer()
        cancelAutoStopRecordingTimer()
        cancelSilenceDetection()
        cleanupStreamingSTT()
        setIsAutoRecording(false)
        speechDetectedDuringAutoRecord = false
        showAnswerConfirmation = false
        pendingResponse = nil
        transcriptWasEdited = false
        preEditTranscript = nil
        transcribedAnswer = ""
        liveTranscript = ""
        transition(to: .askingQuestion)
        setErrorMessage(nil)

        Logger.quiz.info("🚫 Voice submission cancelled by user")
    }
}
