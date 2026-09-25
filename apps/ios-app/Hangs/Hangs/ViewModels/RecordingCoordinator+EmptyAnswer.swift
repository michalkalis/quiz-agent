//
//  RecordingCoordinator+EmptyAnswer.swift
//  Hangs
//
//  #185 track B — an empty answer never skips a question silently.
//
//  Car test 2026-09-23: an answer cut off at 5 s came back empty, the empty
//  confirmation sheet's 5 s auto-confirm ran out, and confirming an empty field
//  IS a skip — the next question appeared with no result and no word from the
//  app. Founder decision 1.1 (2026-09-24):
//
//  1. first miss on a question → the app says "I didn't catch your answer,
//     please try again" (in the quiz language), shows the same line near the
//     mic (in the app language, with sound or muted) and records again at once —
//     ONE automatic retry;
//  2. any later miss → the confirmation sheet with Again / Skip and NO
//     auto-confirm: the question is skipped only by a tap or a spoken command.
//     The sheet appears without being announced (1.2 was rejected).
//
//  Moved out of +Capture with the funnel it replaces (#171 Track B, which sent
//  every miss straight to an auto-confirming empty sheet).
//

import Foundation
import os

extension RecordingCoordinator {
    // MARK: - The funnel

    /// The single funnel for "the recording produced nothing usable": a batch
    /// capture too short to upload, the backend's 400 "speech not understood",
    /// a response without an evaluation, an empty committed transcript, the
    /// STT commit watchdog — and (#171 Track H) an answer window that ran out
    /// entirely while the app was in the background.
    ///
    /// `owner` is the attempt the failed recording belonged to (#186 step 1);
    /// `nil` means the caller runs synchronously inside the current attempt. A
    /// late failure from an earlier attempt — a 400 from question N landing on
    /// N+1 — is dropped here and never opens anything.
    ///
    /// `prompt` is what the retry says; `allowAutoRetry: false` goes straight
    /// to the sheet (the background case: the driver was not there to hear a
    /// prompt, and the mic must not open by itself on the way back).
    func handleTranscriptionFailure(
        owner: AttemptID? = nil,
        prompt: SpokenPrompt = .didNotCatch,
        allowAutoRetry: Bool = true
    ) {
        let attempt = owner ?? attemptLedger.current
        guard attemptLedger.owns(attempt, "transcriptionFailure") else { return }
        // #185 5.1: a new answer spoken ON the sheet that came back empty keeps
        // the answer it was meant to replace — no retry prompt, no second miss.
        if restoreAfterUnheardReplacement() { return }

        // Diagnostics only: dead air and a spoken-but-lost answer end alike, and
        // the TF loop's first question about a miss is which of the two it was.
        let heardSpeech = speechDetectedDuringAutoRecord
        cancelAutoStopRecordingTimer()
        setIsAutoRecording(false)
        speechDetectedDuringAutoRecord = false
        // No banner: the prompt / the sheet IS the message.
        setErrorMessage(nil)

        let questionKey = attempt.questionId ?? ""
        let retries = allowAutoRetry && emptyAnswerRetryQuestionKey != questionKey
        SentryLog.info("no answer captured", category: .audio, attributes: [
            "heardSpeech": heardSpeech,
            "outcome": retries ? "autoRetry" : "sheet",
            "attempt": attempt.description,
        ])

        if retries {
            emptyAnswerRetryQuestionKey = questionKey
            retryAfterEmptyAnswer(prompt: prompt, owner: attempt)
        } else {
            presentNoAnswerChoice(owner: attempt)
        }
    }

    // MARK: - 1. Automatic retry

    /// Say `prompt`, then open the mic again for the same question. The bridge
    /// runs in `.askingQuestion`, like a re-record, with `isRerecording` set so
    /// a stale question-TTS tail cannot arm a think/answer countdown on top.
    private func retryAfterEmptyAnswer(prompt: SpokenPrompt, owner: AttemptID) {
        cancelAutoConfirm()
        cancelAnswerTimer()
        cancelThinkingTime()
        setIsRerecording(true)

        let speaks = !isMuted()
        if speaks {
            // App TTS: no live input under it (#119/#149) and the command
            // window stays closed while it plays. The recording re-arms the mic.
            stopSilenceDetectionListening()
            isSpeakingRetryPrompt = true
            setPlayingAnswerReadBack(true)
        }

        guard transition(to: .askingQuestion) else {
            finishRetryPrompt()
            return
        }
        // After the transition: leaving the recording/processing pair resets the
        // capture state this lives in. Cleared when the retry recording stops.
        emptyAnswerRetryHintQuestionKey = owner.questionId ?? ""
        attemptLedger.record(.prompt, "emptyAnswer.retry", prompt.rawValue)

        let text = prompt.text(language: promptLanguage)
        let task = Task { [weak self] in
            guard let self else { return }
            if speaks { await self.speakRetryPrompt(text) }
            self.finishRetryPrompt()
            guard !Task.isCancelled,
                  self.quizState() == .askingQuestion,
                  self.attemptLedger.owns(owner, "emptyAnswer.retry")
            else { return }
            await self.startRecording(trigger: .emptyAnswerRetry)
        }
        taskBag.add(task, key: .emptyAnswerRetry)
    }

    private var promptLanguage: CommandLanguage {
        .forQuizLanguage(currentSession()?.language ?? settings().language)
    }

    private func speakRetryPrompt(_ text: String) async {
        do {
            // Bounded: the driver waits in silence with the mic closed until
            // this returns, so a slow TTS round trip skips the line, not the retry.
            let audio = try await withUserFacingTimeout(seconds: 3, clock: clock) {
                try await self.networkService.synthesizeSpeech(text: text)
            }
            try Task.checkCancellation()
            _ = try await audioService.playOpusAudio(audio)
        } catch is CancellationError {
            // superseded — whoever cancelled owns what happens next
        } catch {
            guard !Task.isCancelled else { return } // a cancel surfacing as URLError
            // The retry still happens: a silent re-record beats a dead question.
            Logger.audio.warning("🔈 Retry prompt failed: \(error, privacy: .public)")
            SentryLog.warn("retry prompt TTS failed", category: .audio, attributes: [
                "error_type": String(describing: type(of: error)),
            ])
        }
    }

    /// Drop the prompt's command-window latch. Idempotent.
    func finishRetryPrompt() {
        guard isSpeakingRetryPrompt else { return }
        isSpeakingRetryPrompt = false
        setPlayingAnswerReadBack(false)
    }

    /// Stop an in-flight retry prompt (a tap on the mic, a teardown). The
    /// cancelled task then finds its attempt gone and records nothing.
    func cancelRetryPrompt() {
        guard isSpeakingRetryPrompt else { return }
        finishRetryPrompt()
        taskBag.cancel(.emptyAnswerRetry)
        Task { [audioService] in await audioService.stopPlayback() }
    }

    // MARK: - 2. The Again / Skip sheet

    /// The second miss: the confirmation sheet with an empty field, Again and
    /// Skip — and no auto-confirm. Skip (or a spoken confirm) goes through
    /// `confirmAnswer()`, whose empty branch submits the backend's skip.
    private func presentNoAnswerChoice(owner: AttemptID) {
        // The sheet is a `.processing` screen; the upload paths are already
        // there and `.processing → .processing` is not a legal edge.
        if quizState() != .processing {
            guard transition(to: .processing) else { return }
        }
        cancelAutoConfirm()
        pendingResponse = nil
        transcribedAnswer = ""
        noAnswerCaptured = true
        confirmationOwner = owner
        showAnswerConfirmation = true
        // #77 (77.5): "again" / "ok" work here like on any confirmation.
        refreshCommandWindow()
        verifyConfirmationInvariants(after: "noAnswerSheet")
        Logger.stt.info("🎙️ Nothing captured again — Again/Skip sheet, no auto-confirm")
    }

    // MARK: - Invariants (#186 step 1)

    /// The confirmation sheet is a `.processing` screen of the CURRENT attempt —
    /// the car-test bug was exactly a sheet opened by question N's late result
    /// on top of question N+1.
    func verifyConfirmationInvariants(after context: String) {
        guard showAnswerConfirmation else { return }
        if quizState() != .processing {
            attemptLedger.reportInvariantViolation(
                "confirmation sheet only in .processing",
                "state=\(quizState().label) at \(context)"
            )
        }
        if let owner = confirmationOwner, !attemptLedger.isCurrent(owner) {
            attemptLedger.reportInvariantViolation(
                "confirmation sheet belongs to the current attempt",
                "owner=\(owner) at \(context)"
            )
        }
    }
}
