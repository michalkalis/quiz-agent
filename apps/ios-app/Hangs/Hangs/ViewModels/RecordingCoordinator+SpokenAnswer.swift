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
//   5.1  (reversed by #243.5, founder 2026-11-24) anything said on the sheet
//        was a new answer. The sheet now listens for "again" only; any other
//        speech is ignored, and silence until the countdown ends = confirmed.
//   5.2  the countdown starts only once the command listener is live.
//   (5.3, "stop" holds the countdown, went with the stop command on
//   2026-11-22: "again" is the sheet's one word now.)
//
//  Speech still holds the countdown while it lasts, so a slow "again" is not
//  beaten by the auto-confirm; an utterance that was not "again" resumes it.
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
            && !transcriptWasEdited && !isEvaluatingAnswer
    }

    // MARK: - 5.2 The countdown waits for a live mic

    /// Bring the sheet's command listener up; once it is live, start the
    /// auto-confirm countdown. Every voice-sheet opening
    /// comes through here, and so does the resume from a pause.
    func armConfirmationCountdown() {
        guard showAnswerConfirmation, !noAnswerCaptured else { return }
        countdownHold = .awaitingListener
        cancelAutoConfirm()
        let owner = confirmationOwner ?? attemptLedger.current
        let answer = transcribedAnswer
        let task = Task { [weak self] in
            guard let self else { return }
            let live = await self.armCommandWindow()
            guard !Task.isCancelled, self.isAnswerSheetOpen, self.transcribedAnswer == answer,
                  self.attemptLedger.owns(owner, "confirmation.listener") else { return }
            self.attemptLedger.record(.speech, live ? "confirmation.listenerLive" : "confirmation.noListener")
            // Speech that arrived meanwhile keeps its hold.
            guard self.countdownHold == .awaitingListener else { return }
            self.countdownHold = nil
            self.startAutoConfirmIfEnabled()
        }
        taskBag.add(task, key: .confirmationCountdown)
    }

    // MARK: - Speech on the sheet

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
        case .speech:
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
            break // its action already ran
        case .noise:
            resumeCountdownAfterSpeech()
        }
    }

    private func resumeCountdownAfterSpeech() {
        guard countdownHold == .speech else { return }
        taskBag.cancel(.confirmationSpeechHold)
        countdownHold = nil
        guard isAnswerSheetOpen else { return }
        startAutoConfirmIfEnabled() // a FULL window again, like a resumed pause
    }
}
