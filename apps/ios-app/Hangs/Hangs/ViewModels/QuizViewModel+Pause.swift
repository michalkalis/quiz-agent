//
//  QuizViewModel+Pause.swift
//  Hangs
//
//  #171 Track D introduced a real pause, but only on the answer confirmation
//  sheet. #173 (founder locked 2026-09-07, decision 4) moves it into the quiz
//  TOOLBAR, so it has to work from every state the driver can be in — the
//  question is being read, the think window is draining, the mic is open, or
//  the confirmation sheet is up.
//
//  Paused = every running countdown FROZEN and the app silent. It is not a new
//  screen and not a new state-machine case: whatever the driver was looking at
//  stays on screen, it just stops moving.
//
//  Two rules the shape follows:
//   - Resuming re-arms a FULL window, never the remainder. A pause that quietly
//     shortens the time left to intervene is not a pause.
//   - A live recording cannot simply be frozen — the ElevenLabs stream is not
//     resumable, and dropping it would lose what was already said. So pausing
//     mid-recording routes through the EXISTING stop/submit funnel and lands on
//     the confirmation sheet, already paused: nothing spoken is lost, and the
//     driver decides what to do with it whenever they come back.
//

import Foundation
import os

extension QuizViewModel {
    /// States where a pause has something to freeze. The result screen is
    /// deliberately absent — it has its own STAY pill (`pauseQuiz()`, #131 D),
    /// which holds auto-advance while keeping the command listener up.
    var canPauseQuiz: Bool {
        switch quizState {
        case .askingQuestion, .recording: return true
        case .processing: return showAnswerConfirmation
        default: return false
        }
    }

    /// Freeze the quiz. Idempotent, and a no-op in a state with nothing to
    /// freeze — a spoken "pauza" that lands just after an auto-confirm must not
    /// pause the result screen it fired into.
    func enterPause() {
        guard !isPaused, canPauseQuiz else { return }
        let state = quizState
        isPaused = true

        // Countdowns are CANCELLED, never suspended — `exitPause()` re-arms a
        // full window, the only reading of "pause" that does not quietly
        // shorten the time left to intervene.
        quizTimersController.cancelAutoConfirm()
        quizTimersController.cancelThinkingTime()
        quizTimersController.cancelAnswerTimer()

        // Silence anything still speaking: a paused quiz that keeps reading the
        // question out loud is not paused to the passenger who asked for it.
        Task { [weak self] in await self?.audioDeviceState.stopAnyPlayingAudio() }

        // Takes the mic down via `mayCaptureAudio` (which reports false while
        // the quiz is paused), so it also survives a background/foreground round
        // trip — `.active` re-runs this same sync and re-arms nothing.
        voiceCommandCoordinator.refreshCommandWindow()

        // An open mic has speech in it that the driver has not heard back yet.
        // Reuse the one funnel that turns a recording into a reviewable answer
        // instead of inventing a second way to end one.
        if state == .recording {
            Task { [weak self] in await self?.recordingCoordinator.stopRecordingAndSubmit() }
        }

        Logger.quiz.info("⏸️ Quiz paused from \(String(describing: state), privacy: .public)")
    }

    /// Un-freeze: a FULL window again, and the command listener back up.
    /// The toolbar is the only way back — pausing stopped the listener, so no
    /// spoken word can reach us while paused (by design: a resume word would
    /// need a hot mic, which is what pause just turned off).
    func exitPause() {
        guard isPaused else { return }
        isPaused = false

        if showAnswerConfirmation {
            quizTimersController.startAutoConfirmIfEnabled()
        } else if quizState == .askingQuestion {
            // Re-arms the thinking-time countdown or the answer timer, whichever
            // this session's settings use — the same entry point the question
            // flow itself calls, so resume can never diverge from a fresh ask.
            startRecordingOrTimer()
        }
        voiceCommandCoordinator.refreshCommandWindow()

        Logger.quiz.info("▶️ Quiz resumed")
    }

    /// The toolbar's single pause/resume control (and the spoken "pauza").
    func togglePause() {
        if isPaused {
            exitPause()
        } else {
            enterPause()
        }
    }
}
