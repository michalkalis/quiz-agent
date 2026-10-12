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
//  The rules the shape follows:
//   - #200 (founder, TF 2026-10-12): the question screen continues where the
//     pause stopped it. A question read is HELD, not ended, and play continues
//     the same clip (read again from the start if it was lost meanwhile —
//     never straight to the countdown); the think window continues with what
//     it had left (a full window if nothing was left, or the pause hit during
//     the read).
//   - The confirmation sheet's auto-confirm re-arms a FULL window, never the
//     remainder: after a pause the driver has to look at the answer again
//     before it sends itself, and the last second or two would not give them
//     that.
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

        // Auto-confirm is cancelled (play re-arms its full window); the think
        // window keeps what it had left for play to continue (#200).
        quizTimersController.cancelAutoConfirm()
        quizTimersController.holdThinkingTime()

        // Silence anything still speaking: a paused quiz that keeps reading the
        // question out loud is not paused to the passenger who asked for it.
        // The question read is held rather than ended (#200), so play can
        // continue it.
        if !audioDeviceState.holdQuestionReadOut() {
            Task { [weak self] in await self?.audioDeviceState.stopAnyPlayingAudio() }
        }

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

    /// Un-freeze: the question screen continues where it stopped (#200), the
    /// confirmation sheet gets a full auto-confirm window, and the command
    /// listener comes back up.
    /// The toolbar is the only DELIBERATE way back — pausing stopped the
    /// listener, so no spoken word can reach us while paused (by design: a
    /// resume word would need a hot mic, which is what pause just turned off).
    /// Answering, skipping, confirming and re-recording clear the flag on their
    /// own: acting on the question is resuming, and a pause that survived onto
    /// the result screen would silently kill its auto-advance.
    func exitPause() {
        guard isPaused else { return }
        isPaused = false

        if showAnswerConfirmation, !noAnswerCaptured {
            // #185 5.2: the countdown waits for the listener, which this call
            // brings back up itself. Always the FULL window (see the header).
            recordingCoordinator.armConfirmationCountdown()
        } else {
            // The no-answer sheet has no countdown, but its "znova" /
            // "preskoč" listener must come back all the same (PR #199 review).
            if quizState == .askingQuestion {
                resumeQuestionScreen()
            }
            voiceCommandCoordinator.refreshCommandWindow()
        }

        Logger.quiz.info("▶️ Quiz resumed")
    }

    /// #200: the read and the think window pick up where the pause left them.
    /// Re-arming goes through `startRecordingOrTimer`, the entry point the
    /// question flow itself uses, so resume can never diverge from a fresh ask.
    private func resumeQuestionScreen() {
        let heldSeconds = quizTimersController.takeHeldThinkingTime()
        switch audioDeviceState.releaseQuestionReadOut() {
        case .continuing:
            // The initial read's own tail arms the think window. A remainder
            // means the window was already running under a tap-to-replay.
            if heldSeconds > 0 { startRecordingOrTimer(resumingAt: heldSeconds) }
        case .lost where heldSeconds == 0:
            // Never straight to the countdown over a question the driver only
            // half heard: read it again; its tail arms the full window.
            Task { [weak self] in await self?.repeatQuestion() }
        case .lost, .notHeld:
            startRecordingOrTimer(resumingAt: heldSeconds)
        }
    }

    /// The toolbar's single pause/resume control (and the spoken "pauza").
    func togglePause() {
        attemptLedger.record(.tap, "pause") // #186 step 2: replayable black box
        if isPaused {
            exitPause()
        } else {
            enterPause()
        }
    }
}
