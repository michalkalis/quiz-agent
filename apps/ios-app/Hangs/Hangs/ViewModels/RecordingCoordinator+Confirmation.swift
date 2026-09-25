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

/// Who confirmed the sheet (#185 track B).
enum ConfirmTrigger: Equatable, Sendable {
    /// A tap or a spoken confirm — the driver's decision.
    case user
    /// The auto-confirm countdown, armed for the attempt it carries.
    case autoConfirm(AttemptID)
}

extension RecordingCoordinator {
    /// Confirm the transcribed answer and proceed to show result
    func confirmAnswer(trigger: ConfirmTrigger = .user) async {
        // #185 5.1: a new spoken answer is still being transcribed — there is
        // nothing on the sheet to confirm yet (a spoken "potvrď" can land here).
        guard spokenReplacement == nil else {
            attemptLedger.record(.command, "confirm.ignoredWhileTranscribing")
            return
        }
        if case let .autoConfirm(owner) = trigger {
            // #186 step 1: a countdown armed for an earlier attempt never fires.
            guard attemptLedger.owns(owner, "autoConfirm.fire") else { return }
            // #185 1.1 (founder 2026-09-24): confirming an empty field IS a
            // skip, and a countdown may never skip a question — only the driver
            // can. The no-answer sheet does not arm the countdown at all; this
            // is the pin that keeps any other route from doing it either.
            let isEmpty = transcribedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isEmpty, pendingResponse == nil {
                cancelAutoConfirm()
                noAnswerCaptured = true
                attemptLedger.record(.timer, "autoConfirm.refusedEmpty")
                SentryLog.warn("auto-confirm of an empty answer refused", category: .quiz, attributes: [
                    "attempt": owner.description,
                ])
                return
            }
            attemptLedger.record(.timer, "autoConfirm.fire")
        }
        let owner = confirmationOwner ?? attemptLedger.current
        cancelAnswerReadBack()
        cancelAutoConfirm()
        stopSheetCapture() // #185 5.1: the sheet stops listening for a new answer
        clearPause()
        // #100.2 / #79: the sheet flag is this call's single-flight token. A
        // stray or concurrent second confirm finds it already down, and must not
        // reach the empty-answer branch below — an emptied transcript is how a
        // *consumed* confirmation looks too, and skipping there would submit a
        // second answer for the question the first call just graded.
        let wasShowingSheet = showAnswerConfirmation
        showAnswerConfirmation = false

        // #173 C2: the sheet does NOT go away here any more — it stays up in its
        // evaluating state until the result lands, so the driver watches the
        // button they pressed do the work instead of a full-screen overlay
        // replacing the screen. The single-flight token above is untouched:
        // this flag only keeps the presentation alive.
        isEvaluatingAnswer = wasShowingSheet
        defer { isEvaluatingAnswer = false }

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
        let answer = transcribedAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        transcribedAnswer = ""
        noAnswerCaptured = false
        // #186 (founder 2026-09-25): the answer on the sheet is sent — "stop"
        // and "again" can no longer reopen the question (see rerecordAnswer).
        if wasShowingSheet { attemptLedger.markAnswerSent() }

        // If we have a pending Whisper response, use it directly
        if let response = pendingResponse {
            pendingResponse = nil
            await handleQuizResponse(response, owner)
            return
        }

        // #171 Track B: an empty field IS an answer — "no answer". It arrives
        // two ways: the sheet was opened empty because nothing was captured, or
        // the driver cleared the transcript and confirmed. Either way the quiz
        // must reach a RESULT, not sit in .processing with the sheet gone. The
        // backend already has that contract — a skip returns an evaluated
        // response — so route through it instead of inventing a payload.
        guard !answer.isEmpty else {
            guard wasShowingSheet, transition(to: .askingQuestion) else { return }
            await skipQuestion()
            return
        }

        // Streaming STT path: submit the transcribed text via /sessions/{id}/input
        // An edited transcript is the driver's typing, not a spoken answer.
        await resubmitAnswer(answer, silent, !silent)
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
        cancelAnswerReadBack()
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
        cancelAnswerReadBack()
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
        // #186 (founder 2026-09-25, found by the sequence harness): once the
        // answer is sent, "again" is too late — dropped, not a reopened
        // question racing the advance to the next one.
        guard !attemptLedger.refuseAfterAnswerSent("rerecord.afterAnswerSent") else { return }
        // #186 step 1: the rejected recording's attempt ends here — its upload,
        // read-back or late 400 can no longer land on the re-record.
        let owner = attemptLedger.begin("rerecord")
        cancelAnswerReadBack()
        cancelAutoConfirm()
        clearPause()
        // The sheet can also be reached from `.processing` while the voice upload is
        // still in flight (the command screen maps `.processing` → `.confirmation`, so
        // a spoken "again" lands here mid-submit). That submission is answering the
        // recording the driver just rejected — leave it running and its completion
        // resurfaces the stale transcript on top of the live re-record. Cancel it,
        // exactly as `cancelProcessing()` does (#133 V14).
        taskBag.cancel(.voiceSubmission)
        showAnswerConfirmation = false
        isEvaluatingAnswer = false
        pendingResponse = nil
        noAnswerCaptured = false
        transcriptWasEdited = false
        preEditTranscript = nil
        setIsRerecording(true)
        cancelAnswerTimer()
        cancelThinkingTime()
        transition(to: .askingQuestion) // Transient bridge state before recording starts
        setErrorMessage(nil)
        Task { [weak self] in
            guard let self, self.attemptLedger.owns(owner, "rerecord.start") else { return }
            await self.startRecording(trigger: .rerecord)
        }
    }

    /// Cancel the processing operation and return to question state
    func cancelProcessing() {
        // #186 (founder 2026-09-25): a sent answer cannot be taken back — a
        // spoken "stop" after the confirm is dropped (see rerecordAnswer).
        guard !attemptLedger.refuseAfterAnswerSent("cancelProcessing.afterAnswerSent") else { return }
        // #186 step 1: whatever the cancelled attempt still has in flight is void.
        attemptLedger.begin("cancelProcessing")
        cancelAnswerReadBack()
        cancelAutoConfirm()
        clearPause()
        taskBag.cancel(.voiceSubmission)
        taskBag.cancel(.sttCommitWatchdog)
        cancelAnswerTimer()
        cancelAutoStopRecordingTimer()
        cancelSilenceDetection()
        cleanupStreamingSTT()
        abandonAnswerCapture()
        setIsAutoRecording(false)
        speechDetectedDuringAutoRecord = false
        showAnswerConfirmation = false
        isEvaluatingAnswer = false
        pendingResponse = nil
        noAnswerCaptured = false
        transcriptWasEdited = false
        preEditTranscript = nil
        transcribedAnswer = ""
        liveTranscript = ""
        transition(to: .askingQuestion)
        setErrorMessage(nil)

        Logger.quiz.info("🚫 Voice submission cancelled by user")
    }
}
