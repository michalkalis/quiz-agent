//
//  QuizViewModel+Pause.swift
//  Hangs
//
//  #171 Track D — a real pause, and it lives on the answer confirmation sheet
//  (founder decision 2026-09-05). After Tracks B + I the sheet is the universal
//  "after answer" point: every recording, empty or not, and every MCQ voice
//  match lands there. That makes it the only screen where stopping the clock
//  cannot lose an in-flight question, a live recording or an unsubmitted
//  answer — so it is the one place a pause is offered, by pill or by voice.
//
//  Paused = the sheet FROZEN, not a new screen and not a new state-machine
//  case: auto-confirm cancelled, TTS silenced, the command listener down.
//  Confirm / edit / re-record keep working throughout — using them IS resuming.
//

import Foundation
import os

extension QuizViewModel {
    /// Freeze the answer confirmation sheet. Idempotent, and a no-op once the
    /// sheet is gone — a spoken "pauza" that lands just after an auto-confirm
    /// must not pause the result screen it fired into.
    func pauseOnConfirmation() {
        guard showAnswerConfirmation, !isPaused else { return }
        isPaused = true

        // The countdown is CANCELLED, never restarted — resuming re-arms a full
        // window (`resumeFromConfirmation`), which is the only reading of "pause"
        // that does not quietly shorten the time left to intervene.
        quizTimersController.cancelAutoConfirm()

        // Silence anything still speaking: a paused quiz that keeps reading the
        // feedback out loud is not paused to the passenger who asked for it.
        Task { [weak self] in await self?.audioDeviceState.stopAnyPlayingAudio() }

        // Takes the mic down via `mayCaptureAudio` (which now reports false while
        // a paused sheet is up), so it also survives a background/foreground
        // round trip — `.active` re-runs this same sync and re-arms nothing.
        voiceCommandCoordinator.refreshCommandWindow()

        Logger.quiz.info("⏸️ Paused on the answer confirmation sheet")
    }

    /// Un-freeze the sheet: a FULL auto-confirm window again, and the command
    /// window back up. The pill is the only way back — pausing stopped the
    /// listener, so no spoken word can reach us while paused (by design: a
    /// resume word would need a hot mic, which is what pause just turned off).
    func resumeFromConfirmation() {
        guard isPaused else { return }
        isPaused = false

        quizTimersController.startAutoConfirmIfEnabled()
        voiceCommandCoordinator.refreshCommandWindow()

        Logger.quiz.info("▶️ Resumed from the answer confirmation sheet")
    }

    /// The sheet's single Pause/Continue control.
    func toggleConfirmationPause() {
        if isPaused {
            resumeFromConfirmation()
        } else {
            pauseOnConfirmation()
        }
    }
}
