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
//  #243.4 (founder 2026-11-24, decision 2; TF 2026-11-22/23 B1, B2): a window
//  that heard nothing is a player still thinking, not a miss to retry. On the
//  first silence the quiz goes back to thinking, without a word or a hint:
//  "Think more." and a fresh window, the mic opens when it runs out. The spoken
//  hint and the at-once retry stay for a player the app heard but did not
//  understand. The sheet now says its choices ("Repeat the question, again, or
//  next?") before it listens for them, and "repeat" leads back to the question.
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
    /// `heardSpeech` (#243.4): whether the player was heard at all; `nil` =
    /// what the stopped recording's voice detector heard.
    func handleTranscriptionFailure(
        owner: AttemptID? = nil,
        prompt: SpokenPrompt = .didNotCatch,
        allowAutoRetry: Bool = true,
        heardSpeech: Bool? = nil
    ) {
        let attempt = owner ?? attemptLedger.current
        guard attemptLedger.owns(attempt, "transcriptionFailure") else { return }
        // #185 5.1: a new answer spoken ON the sheet that came back empty keeps
        // the answer it was meant to replace — no retry prompt, no second miss.
        if restoreAfterUnheardReplacement() { return }

        // #243.4: dead air and a spoken-but-lost answer now end differently.
        let heardSpeech = heardSpeech ?? stoppedRecordingHeardSpeech
        cancelAutoStopRecordingTimer()
        setIsAutoRecording(false)
        speechDetectedDuringAutoRecord = false
        // No banner: the prompt / the sheet IS the message.
        setErrorMessage(nil)

        let questionKey = attempt.questionId ?? ""
        // #189 M3: a paused quiz never reopens the mic by itself. Pausing
        // mid-recording submits what was said; when that comes back empty it
        // lands on Again / Skip (no countdown) — the automatic retry is the
        // driver's to take once they resume.
        let paused = isPaused()
        let retries = allowAutoRetry && !paused && emptyAnswerRetryQuestionKey != questionKey
        // #243.4: only the generic line can mean silence; an MCQ line means the
        // server heard an answer naming no option.
        let thinksAgain = retries && prompt == .didNotCatch && !heardSpeech
        SentryLog.info("no answer captured", category: .audio, attributes: [
            "heardSpeech": heardSpeech,
            "outcome": thinksAgain ? "thinkAgain" : retries ? "autoRetry" : "sheet",
            "attempt": attempt.description,
            "paused": paused,
        ])

        if thinksAgain {
            emptyAnswerRetryQuestionKey = questionKey
            thinkAgainAfterSilence(owner: attempt)
        } else if retries {
            emptyAnswerRetryQuestionKey = questionKey
            retryAfterEmptyAnswer(prompt: prompt, owner: attempt)
        } else {
            presentNoAnswerChoice()
        }
    }

    // MARK: - 1a. Silence: back to thinking (#243.4)

    /// Back to the open question with a fresh think window that says "Think
    /// more." (`takeThinkMore`). No line, no hint, and the mic stays shut until
    /// that window runs out or the player asks for it.
    private func thinkAgainAfterSilence(owner: AttemptID) {
        cancelAutoConfirm()
        cancelThinkingTime()
        // A re-record earlier on this question latched it; the new window must
        // not find itself blocked by it.
        setIsRerecording(false)
        guard transition(to: .askingQuestion) else { return }
        thinkMoreQuestionKey = owner.questionId ?? ""
        attemptLedger.record(.prompt, "emptyAnswer.thinkAgain")
        refreshCommandWindow()
        startThinkingTime()
    }

    /// Whether the think window that starts now on `questionId` is the one
    /// after a silence. One-shot: every phase cue consumes it.
    func takeThinkMore(questionId: String?) -> Bool {
        defer { thinkMoreQuestionKey = nil }
        return thinkMoreQuestionKey != nil && thinkMoreQuestionKey == (questionId ?? "")
    }

    // MARK: - 1. Automatic retry

    /// Say `prompt`, then open the mic again for the same question. The bridge
    /// runs in `.askingQuestion`, like a re-record, with `isRerecording` set so
    /// a stale question-TTS tail cannot arm a think/answer countdown on top.
    private func retryAfterEmptyAnswer(prompt: SpokenPrompt, owner: AttemptID) {
        cancelAutoConfirm()
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
        emptyAnswerRetryPrompt = prompt
        attemptLedger.record(.prompt, "emptyAnswer.retry", prompt.rawValue)

        let text = prompt.text(language: promptLanguage)
        if speaks { noteSpokenLine(text) }
        let task = Task { [weak self] in
            guard let self else { return }
            if speaks { await self.speakRetryPrompt(text) }
            self.finishRetryPrompt()
            guard !Task.isCancelled,
                  self.quizState() == .askingQuestion,
                  self.attemptLedger.owns(owner, "emptyAnswer.retry")
            else { return }
            // #189 M3: paused while the prompt played — the mic stays shut.
            // P9: drop the re-record latch too, or resuming finds this
            // question's own window (`startRecordingOrTimer`) blocked by it and
            // the question sits with no countdown and no mic.
            guard !self.isPaused() else {
                self.setIsRerecording(false)
                self.attemptLedger.record(.prompt, "emptyAnswer.retryHeldByPause")
                return
            }
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
            let language = currentSession()?.language ?? settings().language
            let audio = try await withUserFacingTimeout(seconds: 3, clock: clock) {
                try await self.networkService.synthesizeSpeech(text: text, language: language)
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

    // MARK: - 2. The Repeat / Again / Skip sheet

    /// The second miss: the confirmation sheet with an empty field, Again and
    /// Skip — and no auto-confirm. Skip (or a spoken confirm) goes through
    /// `confirmAnswer()`, whose empty branch submits the backend's skip.
    /// #243.4: also "Repeat question", and the sheet says its choices first.
    private func presentNoAnswerChoice() {
        // The sheet is a `.processing` screen; the upload paths are already
        // there and `.processing → .processing` is not a legal edge.
        if quizState() != .processing {
            guard transition(to: .processing) else { return }
        }
        // #189 M5: the sheet is the driver's NEW decision, so it gets a new
        // attempt. Owned by the failed one, a sheet opened after a typed or
        // edited answer the server could not place belonged to an attempt
        // already marked sent — and Again / Cancel were refused on it. It also
        // voids anything the failed attempt still has in flight.
        let sheetOwner = attemptLedger.begin("noAnswerSheet")
        cancelAutoConfirm()
        pendingResponse = nil
        transcribedAnswer = ""
        noAnswerCaptured = true
        confirmationOwner = sheetOwner
        showAnswerConfirmation = true
        offerNoAnswerChoices(owner: sheetOwner)
        verifyConfirmationInvariants(after: "noAnswerSheet")
        Logger.stt.info("🎙️ Nothing captured again — Repeat/Again/Skip sheet, no auto-confirm")
    }

    /// #243.4: "Repeat the question, again, or next?" in the app voice, and
    /// only then the sheet's command window (founder: commands are listened
    /// for after a line that names them). Silent with read-aloud off, in a
    /// silent quiz or under a pause; the window then opens at once (a pause
    /// keeps it shut until play). Shares the retry prompt's latch, so a tap
    /// or a teardown stops it like that line.
    private func offerNoAnswerChoices(owner: AttemptID) {
        guard !isMuted(), !isSilentMode(), !isPaused() else {
            refreshCommandWindow()
            return
        }
        // Long the first times a player hears it, short after (counted here).
        let offer = takeNoAnswerOffer()
        guard let audio = offer.audio(language: promptLanguage) else {
            refreshCommandWindow()
            return
        }
        stopSilenceDetectionListening()
        isSpeakingRetryPrompt = true
        setPlayingAnswerReadBack(true)
        attemptLedger.record(.prompt, "phase", offer.resourceName)
        noteSpokenLine(offer.text(language: promptLanguage))
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await audioService.playOpusAudio(audio)
            } catch {
                // Stopped (a tap, a pause) or failed: the sheet still listens.
                Logger.audio.warning("🔈 No-answer offer cut: \(error, privacy: .public)")
            }
            finishRetryPrompt()
            guard !Task.isCancelled, attemptLedger.owns(owner, "noAnswerSheet.offer") else { return }
            refreshCommandWindow()
        }
        taskBag.add(task, key: .emptyAnswerRetry)
    }

    /// #243.4 (B2): "Repeat question" on the no-answer sheet. Closes the
    /// sheet as a new attempt and reopens the question; the caller reads it
    /// again. `false` = no such sheet up (or the move lost a race).
    func leaveNoAnswerSheetForQuestion() async -> Bool {
        guard showAnswerConfirmation, noAnswerCaptured, quizState() == .processing else { return false }
        let owner = attemptLedger.begin("noAnswer.repeat")
        let wasSpeaking = isSpeakingRetryPrompt
        finishRetryPrompt()
        taskBag.cancel(.emptyAnswerRetry)
        cancelAutoConfirm()
        clearPause()
        showAnswerConfirmation = false
        noAnswerCaptured = false
        pendingResponse = nil
        // The question read's tail arms the think window only without it.
        setIsRerecording(false)
        guard transition(to: .askingQuestion) else { return false }
        if wasSpeaking { await audioService.stopPlayback() }
        return attemptLedger.owns(owner, "noAnswer.repeat")
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
