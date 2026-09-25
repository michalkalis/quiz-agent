//
//  RecordingCoordinator+SpokenAnswer.swift
//  Hangs
//
//  #185 track D — the answer confirmation sheet listens (car test 2026-09-23).
//  "znova" failed in the car: the 5 s auto-confirm started together with the
//  listener restart after the read-back (up to 3 s of "command mic settled
//  late"), the command then waited for the end-of-speech final, and nothing
//  said the mic was open. Founder decisions of 2026-09-24:
//
//   5.1  anything said on the sheet that is not a command is a NEW answer and
//        replaces the old one; silence until the countdown ends = confirmed.
//   5.2  the countdown starts only once the command listener is live.
//   5.3  "stop" only stops the automatic advance — the sheet then waits.
//
//  How 5.1 works without asking the driver to say it twice: while the sheet is
//  up, the listener's audio is kept (`beginSheetCapture`, the same tee the
//  batch answer uses) and restarted at every utterance boundary. An utterance
//  the command recognizer could not match is uploaded like any recorded answer,
//  so the new answer is transcribed by the same service as the first one — the
//  on-device recognizer is biased toward command words and weaker in the cabin.
//  Speech holds the countdown so it never confirms the old answer mid-sentence.
//

import Foundation
import os

extension RecordingCoordinator {
    /// How long speech may hold the countdown without the recognizer ending the
    /// utterance — a recognizer that never finalizes must not freeze the sheet.
    static let speechHoldLimitSeconds = 10

    /// The sheet shows an answer the driver can still act on by voice: not the
    /// no-answer choice, not being typed, graded or re-transcribed.
    var isAnswerSheetOpen: Bool {
        showAnswerConfirmation && quizState() == .processing && !noAnswerCaptured
            && !transcriptWasEdited && !isEvaluatingAnswer && spokenReplacement == nil
    }

    // MARK: - 5.2 The countdown waits for a live mic

    /// Bring the sheet's command listener up; once it is live, keep its audio
    /// (5.1) and start the auto-confirm countdown. Every voice-sheet opening
    /// comes through here, and so does the resume from a pause.
    func armConfirmationCountdown() {
        guard showAnswerConfirmation, !noAnswerCaptured else { return }
        if countdownHold != .driverStop { countdownHold = .awaitingListener }
        cancelAutoConfirm()
        let owner = confirmationOwner ?? attemptLedger.current
        let answer = transcribedAnswer
        let task = Task { [weak self] in
            guard let self else { return }
            let live = await self.armCommandWindow()
            guard !Task.isCancelled, self.isAnswerSheetOpen, self.transcribedAnswer == answer,
                  self.attemptLedger.owns(owner, "confirmation.listener") else { return }
            self.attemptLedger.record(.speech, live ? "confirmation.listenerLive" : "confirmation.noListener")
            if live { self.beginSheetCapture() }
            // A "stop" or speech that arrived meanwhile keeps its hold.
            guard self.countdownHold == .awaitingListener else { return }
            self.countdownHold = nil
            self.startAutoConfirmIfEnabled()
        }
        taskBag.add(task, key: .confirmationCountdown)
    }

    // MARK: - 5.3 "stop"

    /// Spoken "stop": the countdown stops and stays stopped while this sheet is
    /// up. The listener keeps running — "potvrď", "znova", a new answer or a
    /// tap decide.
    func holdAutoConfirmByDriver() {
        guard showAnswerConfirmation, !noAnswerCaptured, !isEvaluatingAnswer else { return }
        countdownHold = .driverStop
        taskBag.cancel(.confirmationSpeechHold)
        cancelAutoConfirm()
        Logger.quiz.info("✋ Auto-confirm stopped by voice")
    }

    // MARK: - 5.1 Speech on the sheet

    /// Someone is speaking on the sheet: a running countdown must not confirm
    /// the old answer under them. Resumed (a full window) when the utterance
    /// ends in nothing, or after `speechHoldLimitSeconds`.
    func holdCountdownForSpeech() {
        guard isAnswerSheetOpen else { return }
        switch countdownHold {
        case nil:
            guard autoConfirmCountdown > 0 else { return } // nothing is counting down
        case .awaitingListener:
            break // the countdown must not start under this utterance either
        case .speech, .driverStop:
            return
        }
        countdownHold = .speech
        cancelAutoConfirm()
        attemptLedger.record(.speech, "confirmation.speechHold")

        let clock = clock
        let owner = attemptLedger.current
        let task = Task { [weak self] in
            try? await clock.sleep(for: .seconds(Self.speechHoldLimitSeconds))
            guard let self, !Task.isCancelled,
                  self.attemptLedger.owns(owner, "confirmation.speechHoldLimit") else { return }
            self.resumeCountdownAfterSpeech()
        }
        taskBag.add(task, key: .confirmationSpeechHold)
    }

    /// An utterance on the sheet ended (see `ConfirmationUtterance`).
    func handleConfirmationUtterance(_ utterance: ConfirmationUtterance) {
        switch utterance {
        case .command:
            // Its action already ran; its words must not open the next answer.
            restartSheetCapture()
        case .noise:
            restartSheetCapture()
            resumeCountdownAfterSpeech()
        case let .newAnswer(heard):
            submitSpokenReplacement(heard: heard)
        }
    }

    private func resumeCountdownAfterSpeech() {
        guard countdownHold == .speech else { return }
        taskBag.cancel(.confirmationSpeechHold)
        countdownHold = nil
        guard isAnswerSheetOpen else { return }
        startAutoConfirmIfEnabled() // a FULL window again, like a resumed pause
    }

    // MARK: - The sheet's audio

    /// Keep the live listener's audio while the sheet is up. Rolling, so a sheet
    /// left open (after "stop") never grows it without bound.
    private func beginSheetCapture() {
        guard silenceDetectionService.isListening else { return }
        let capture = answerCapture
        capture.begin(sampleRate: Int(silenceDetectionService.answerAudioSampleRate), rolling: true)
        silenceDetectionService.setAnswerAudioSink { capture.append($0) }
        isSheetCaptureActive = true
    }

    /// Start the next utterance's audio from here.
    private func restartSheetCapture() {
        guard isSheetCaptureActive else { return }
        answerCapture.begin(sampleRate: Int(silenceDetectionService.answerAudioSampleRate), rolling: true)
    }

    /// Stop keeping the sheet's audio. Idempotent; never touches a capture it
    /// did not start.
    func stopSheetCapture() {
        guard isSheetCaptureActive else { return }
        isSheetCaptureActive = false
        silenceDetectionService.setAnswerAudioSink(nil)
        answerCapture.cancel()
    }

    // MARK: - 5.1 The new answer

    /// Upload the utterance just heard as the new answer. The sheet shows
    /// "Transcribing…" meanwhile; the old answer is kept until the new one is
    /// known (`resolveSpokenReplacement` / `restoreAfterUnheardReplacement`).
    private func submitSpokenReplacement(heard: String) {
        guard isAnswerSheetOpen, isSheetCaptureActive else {
            restartSheetCapture()
            resumeCountdownAfterSpeech()
            return
        }
        let capture = answerCapture.finish()
        silenceDetectionService.setAnswerAudioSink(nil)
        isSheetCaptureActive = false
        guard capture.bytes >= Self.minimumAnswerBytes(sampleRate: capture.sampleRate) else {
            beginSheetCapture()
            resumeCountdownAfterSpeech()
            return
        }

        // A new attempt: the old answer's read-back, countdown and grade are
        // void from here, and a late result of THIS upload can only land on
        // this sheet (#186 step 1).
        let owner = attemptLedger.begin("sheetAnswer")
        cancelAnswerReadBack()
        cancelAutoConfirm()
        taskBag.cancel(.confirmationSpeechHold)
        if countdownHold != .driverStop { countdownHold = .awaitingListener }
        spokenReplacement = SpokenReplacement(previousAnswer: transcribedAnswer)
        pendingResponse = nil
        transcribedAnswer = "" // the sheet shows "Transcribing…"
        confirmationOwner = owner

        var attributes: [String: Any] = ["durationMs": capture.durationMs, "attempt": owner.description]
        attributes.merge(VoiceCommandCoordinator.heardTextAttributes(heard)) { current, _ in current }
        SentryLog.info("confirmation answer spoken again", category: .audio, attributes: attributes)

        Task { [weak self] in
            // A cancel or re-record that won the race owns the sheet now.
            guard let self, self.attemptLedger.owns(owner, "sheetAnswer.submit") else { return }
            await self.submitVoiceAnswer(audioData: capture.wav, fileName: "answer.wav", owner: owner)
        }
    }

    /// The new answer's transcript arrived. `true` = handled here: it was a
    /// command word the on-device recognizer missed ("Potvrď." is a confirm of
    /// the OLD answer, not an answer), so the old answer comes back and the
    /// command runs. `false` = a real new answer — present it as usual.
    func resolveSpokenReplacement(_ transcript: String) -> Bool {
        guard let replacement = spokenReplacement else { return false }
        spokenReplacement = nil
        let language = CommandLanguage.forQuizLanguage(currentSession()?.language ?? settings().language)
        let command = VoiceCommandMatcher.match(transcript: transcript, on: .confirmation, language: language)
        switch command {
        case .ok:
            attemptLedger.record(.command, "sheetAnswer.wasConfirm")
            restorePreviousAnswer(replacement, readBack: false)
            Task { [weak self] in await self?.confirmAnswer() }
        case .again:
            attemptLedger.record(.command, "sheetAnswer.wasAgain")
            rerecordAnswer()
        case .stop:
            attemptLedger.record(.command, "sheetAnswer.wasStop")
            countdownHold = .driverStop
            restorePreviousAnswer(replacement, readBack: true)
        default:
            return false
        }
        return true
    }

    /// The new answer came back empty (or not understood): keep the old one
    /// rather than drop the driver into the "didn't catch that" retry — the
    /// words the recognizer heard may have been cabin noise. `true` = handled.
    func restoreAfterUnheardReplacement() -> Bool {
        guard let replacement = spokenReplacement, showAnswerConfirmation else { return false }
        spokenReplacement = nil
        attemptLedger.record(.network, "sheetAnswer.unheard")
        SentryLog.info("spoken answer not understood — previous answer kept", category: .audio)
        restorePreviousAnswer(replacement, readBack: true)
        return true
    }

    /// Put the replaced answer back on the sheet. Its grade is gone — the
    /// backend graded the newer audio last — so confirming it re-grades the
    /// text (`confirmAnswer`'s resubmit path).
    private func restorePreviousAnswer(_ replacement: SpokenReplacement, readBack: Bool) {
        pendingResponse = nil
        guard readBack else {
            transcribedAnswer = replacement.previousAnswer
            return
        }
        // Read back, so the driver hears which answer stands.
        presentVoiceTranscript(replacement.previousAnswer)
    }
}
