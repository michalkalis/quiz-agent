//
//  ConfirmResultCommandTests.swift
//  HangsTests
//
//  Issue #77 (voice commands hands-free), task 77.9 — the confirm / result / repeat
//  / skip command wiring. Drives `handleRecognizedCommand` directly (routing seam).
//  Covers:
//    • Confirmation sheet: "ok" → confirmAnswer, "again" → rerecordAnswer, "stop" →
//      cancelProcessing — all ON TOP of the untouched 10 s auto-confirm + buttons;
//    • the 10 s auto-confirm still fires with NO speech (regression guard);
//    • Result: "next" advances (auto-advance untouched);
//    • Question: "repeat" replays the question audio + re-arms the listener;
//    • Question: "skip" opens the ~2.5 s undo-window (commit / abort seam).
//

import ConcurrencyExtras
import Foundation
@testable import Hangs
import SwiftUI
import Testing

@MainActor
private func makeVM() -> (QuizViewModel, MockSilenceDetectionService, MockAudioService) {
    let audio = MockAudioService()
    let silence = MockSilenceDetectionService()
    let vm = QuizViewModel(
        networkService: Fixtures.makeFullMockNetwork(),
        audioService: audio,
        persistenceStore: MockPersistenceStore(),
        silenceDetectionService: silence,
        sttService: nil
    )
    vm.currentSession = Fixtures.makeActiveSession()
    vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
    return (vm, silence, audio)
}

@MainActor
private func makePendingResponse() -> QuizResponse {
    QuizResponse(
        success: true,
        message: "Answered",
        session: Fixtures.makeQuizSession(id: "test_session_123", phase: "asking"),
        currentQuestion: Fixtures.makeQuestion(id: "q_002", text: "Next?", source: "Next"),
        evaluation: Evaluation(
            userAnswer: "an answer", result: .correct, points: 1.0,
            correctAnswer: "an answer", questionId: "q_001", explanation: nil
        ),
        feedbackReceived: ["answer: correct"],
        audio: nil
    )
}

@MainActor
private func makeResultState() -> QuizState {
    .showingResult(
        question: Fixtures.makeQuestion(id: "q_001"),
        evaluation: Evaluation(
            userAnswer: "x", result: .correct, points: 1.0,
            correctAnswer: "x", questionId: "q_001", explanation: nil
        )
    )
}

@MainActor
private func waitUntil(
    _ predicate: @MainActor () -> Bool,
    timeoutMillis: Int = 6000,
    _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMillis))
    while ContinuousClock.now < deadline {
        if predicate() { return }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
    if predicate() { return }
    Issue.record(comment ?? "waitUntil timed out after \(timeoutMillis)ms", sourceLocation: sourceLocation)
}

@Suite("Confirm / Result / Repeat / Skip command wiring (77.9)")
@MainActor
struct ConfirmResultCommandTests {
    // MARK: - Confirmation sheet

    @Test("'ok' on the confirmation sheet confirms the answer")
    func okConfirms() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeVM()
            vm.quizState = .processing
            vm.showAnswerConfirmation = true
            vm.recordingCoordinator.pendingResponse = makePendingResponse()

            vm.voiceCommandCoordinator.handleRecognizedCommand(.ok)

            await waitUntil({ !vm.showAnswerConfirmation }, "ok did not confirm")
            #expect(vm.showAnswerConfirmation == false)
            #expect(vm.recordingCoordinator.pendingResponse == nil, "the pending response was consumed by confirm")
        }
    }

    @Test("'again' on the confirmation sheet re-records immediately (#108A)")
    func againReRecords() async {
        await withMainSerialExecutor {
            let (vm, _, audio) = makeVM()
            vm.quizState = .processing
            vm.showAnswerConfirmation = true
            vm.recordingCoordinator.pendingResponse = makePendingResponse()

            vm.voiceCommandCoordinator.handleRecognizedCommand(.again)

            for _ in 0 ..< 40 {
                await Task.yield()
            }
            #expect(vm.showAnswerConfirmation == false)
            #expect(vm.isRerecording == true)
            // Founder-rejected the old countdown-then-record behavior: "again"
            // must open the mic right away, not park on askingQuestion.
            #expect(vm.quizState == .recording, "re-record must start recording immediately")
            #expect(audio.isRecording == true)
        }
    }

    @Test("'stop' on the confirmation sheet cancels processing")
    func stopCancels() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeVM()
            vm.quizState = .processing
            vm.showAnswerConfirmation = true

            vm.voiceCommandCoordinator.handleRecognizedCommand(.stop)

            for _ in 0 ..< 40 {
                await Task.yield()
            }
            #expect(vm.showAnswerConfirmation == false)
            #expect(vm.quizState == .askingQuestion)
        }
    }

    @Test("the 10 s auto-confirm still fires with NO speech (unchanged fallback)")
    func autoConfirmStillFires() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeVM()
            vm.quizState = .processing
            vm.showAnswerConfirmation = true
            vm.recordingCoordinator.pendingResponse = makePendingResponse()
            vm.settings.autoConfirmEnabled = true

            // No spoken command — the auto-confirm timer alone must confirm.
            vm.quizTimersController.startAutoConfirmIfEnabled(duration: 1)

            await waitUntil({ !vm.showAnswerConfirmation }, "auto-confirm did not fire with no speech")
            #expect(vm.showAnswerConfirmation == false)
        }
    }

    // MARK: - Result

    @Test("'next' on the result screen advances")
    func nextAdvances() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeVM()
            vm.quizState = makeResultState()
            #expect(vm.voiceCommandCoordinator.currentCommandScreen == .result)

            vm.voiceCommandCoordinator.handleRecognizedCommand(.next)

            await waitUntil({ vm.voiceCommandCoordinator.currentCommandScreen != .result }, "next did not advance")
            if case .showingResult = vm.quizState {
                Issue.record("still on the result screen after 'next'")
            }
        }
    }

    @Test("'ok' also advances on the result screen")
    func okAlsoAdvances() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeVM()
            vm.quizState = makeResultState()

            vm.voiceCommandCoordinator.handleRecognizedCommand(.ok)

            await waitUntil({ vm.voiceCommandCoordinator.currentCommandScreen != .result }, "ok did not advance on result")
            if case .showingResult = vm.quizState {
                Issue.record("still on the result screen after 'ok'")
            }
        }
    }

    // MARK: - Repeat

    @Test("'repeat' on the question screen replays the audio and re-arms the listener")
    func repeatReplaysAndReArms() async {
        await withMainSerialExecutor {
            let (vm, silence, audio) = makeVM()
            vm.quizState = .askingQuestion
            vm.recordingCoordinator.currentQuestionAudioUrl = "https://example.com/q.opus"

            vm.voiceCommandCoordinator.handleRecognizedCommand(.repeatQuestion)

            // Durable signals: the question audio was replayed, and once the replay
            // finished the command listener was re-armed (77.9). isPlayingQuestionTTS
            // is only transiently true, so it's not a reliable assertion target.
            await waitUntil({ audio.playOpusCallCount >= 1 }, "repeat did not replay the question")
            await waitUntil({ !vm.isPlayingQuestionTTS && silence.isListening },
                            "listener was not re-armed after replay")
            #expect(audio.playOpusCallCount >= 1)
            #expect(silence.isListening == true)
        }
    }

    // MARK: - Skip undo-window

    @Test("'skip' on the question screen opens the undo-window (does not commit immediately)")
    func skipOpensUndoWindow() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeVM()
            vm.quizState = .askingQuestion

            var earconFired = false
            vm.voiceCommandCoordinator.onSkipUndoWindowOpened = { earconFired = true }

            // Use a long window so it can't commit during the assertion.
            vm.voiceCommandCoordinator.beginSkipUndoWindow(duration: 10)

            #expect(vm.voiceCommandCoordinator.pendingSkipWindow != nil, "skip must open an undo-window, not commit")
            #expect(earconFired == true, "the skip-confirm earcon seam must fire on open")
            #expect(vm.quizState == .askingQuestion, "skip must not commit while the window is open")
        }
    }

    @Test("aborting the skip undo-window cancels the pending skip")
    func skipUndoAbort() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeVM()
            vm.quizState = .askingQuestion
            vm.voiceCommandCoordinator.beginSkipUndoWindow(duration: 10)
            #expect(vm.voiceCommandCoordinator.pendingSkipWindow != nil)

            vm.voiceCommandCoordinator.abortSkipUndoWindow()
            #expect(vm.voiceCommandCoordinator.pendingSkipWindow == nil, "abort must clear the pending skip")
            #expect(vm.quizState == .askingQuestion, "aborted skip never leaves the question")
        }
    }

    @Test("the skip undo-window commits the skip on expiry")
    func skipUndoCommits() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeVM()
            vm.quizState = .askingQuestion

            // Short window so the commit path runs quickly.
            vm.voiceCommandCoordinator.beginSkipUndoWindow(duration: 0.05)

            // On expiry the window commits via skipQuestion() (→ .skipping then advance).
            await waitUntil({ vm.voiceCommandCoordinator.pendingSkipWindow == nil && vm.quizState != .askingQuestion },
                            "skip did not commit on undo-window expiry")
            #expect(vm.voiceCommandCoordinator.pendingSkipWindow == nil)
            #expect(vm.quizState != .askingQuestion, "expiry must commit the skip")
        }
    }
}

// MARK: - #171 Track D — pause on the answer confirmation sheet

/// The founder rule (2026-09-05, LOCKED): the quiz can be paused AFTER
/// answering, and the confirmation sheet is where that happens. These pin what
/// "paused" has to mean for a driver — nothing advances, nothing speaks,
/// nothing listens — and that the shared quiz-level flag did not quietly take
/// the result screen's STAY pill (#131 D) with it.
@Suite("Pause on the answer confirmation sheet (#171 Track D)")
@MainActor
struct ConfirmationPauseTests {
    /// Puts a VM on a live confirmation sheet with a ticking auto-confirm.
    @MainActor
    private func makeSheetVM() -> QuizViewModel {
        let (vm, _, _) = makeVM()
        vm.quizState = .processing
        vm.transcribedAnswer = "Paris"
        vm.showAnswerConfirmation = true
        vm.settings.autoConfirmEnabled = true
        vm.quizTimersController.startAutoConfirmIfEnabled(duration: 5)
        return vm
    }

    /// WHY: a pause that leaves the 5 s timer running is not a pause — it just
    /// hides the number and submits the answer anyway.
    @Test("spoken 'pauza' cancels auto-confirm and closes the command window")
    func voicePauseFreezesTheSheet() async {
        await withMainSerialExecutor {
            let vm = makeSheetVM()
            #expect(vm.autoConfirmCountdown == 5)
            #expect(vm.voiceCommandCoordinator.currentCommandScreen == .confirmation)

            vm.voiceCommandCoordinator.handleRecognizedCommand(.pause)

            #expect(vm.isPaused, "the spoken command must pause the quiz")
            #expect(vm.autoConfirmCountdown == 0, "auto-confirm must be cancelled, not restarted")
            #expect(vm.showAnswerConfirmation, "the sheet stays up — pause freezes it, it does not dismiss it")
            #expect(
                vm.voiceCommandCoordinator.currentCommandScreen == nil,
                "a paused sheet must not keep listening for 'potvrď'"
            )
            #expect(vm.voiceCommandCoordinator.mayCaptureAudio == false, "the mic comes down with the pause")
        }
    }

    /// WHY: resuming must hand back the FULL window. Restarting from whatever
    /// was left when the driver paused would silently shorten the only chance
    /// they have to correct a mis-transcription.
    @Test("Continue re-arms a full 5 s window and re-opens the command window")
    func resumeReArmsTheFullWindow() async {
        await withMainSerialExecutor {
            let vm = makeSheetVM()
            vm.pauseOnConfirmation()
            #expect(vm.autoConfirmCountdown == 0)

            vm.resumeFromConfirmation()

            #expect(vm.isPaused == false)
            #expect(
                vm.autoConfirmCountdown == Config.autoConfirmDelaySecs,
                "resume must re-arm the whole window, not the remainder"
            )
            #expect(vm.voiceCommandCoordinator.currentCommandScreen == .confirmation)
            vm.quizTimersController.cancelAutoConfirm()
        }
    }

    /// WHY (#171 Track H): backgrounding is how a driver pauses in practice —
    /// a call, maps, the passenger's phone. The `.active` handler re-arms the
    /// listener and reopens suppressed answer windows, and it must not undo a
    /// pause the driver explicitly asked for.
    @Test("returning to the foreground while paused stays paused and re-arms nothing")
    func foregroundReturnKeepsThePause() async {
        await withMainSerialExecutor {
            let vm = makeSheetVM()
            vm.pauseOnConfirmation()

            vm.handleScenePhase(.background)
            vm.handleScenePhase(.active)

            #expect(vm.isPaused, "a foreground return must not resume the quiz")
            #expect(vm.autoConfirmCountdown == 0, "the countdown must not restart on return")
            #expect(vm.showAnswerConfirmation, "the frozen sheet survives the round trip")
            #expect(
                vm.voiceCommandCoordinator.currentCommandScreen == nil,
                "the .active handler must not re-arm the listener while paused"
            )
        }
    }


    /// WHY (#171 Track D review): pause exists so the driver can take their
    /// time — and re-recording a mis-heard answer is one of the things they
    /// take it for. Re-record must stay live while paused AND act as a resume,
    /// or a paused sheet has Confirm as its only exit and the next question
    /// would inherit a stale pause that mutes its auto-confirm.
    @Test("re-recording while paused resumes the quiz and opens the mic")
    func reRecordWhilePausedResumesAndRecords() async {
        await withMainSerialExecutor {
            let vm = makeSheetVM()
            vm.pauseOnConfirmation()
            #expect(vm.isPaused)

            vm.recordingCoordinator.rerecordAnswer()

            for _ in 0 ..< 40 {
                await Task.yield()
            }
            #expect(vm.isPaused == false, "re-record must not leave the quiz paused")
            #expect(vm.showAnswerConfirmation == false)
            #expect(vm.quizState == .recording, "re-record opens the mic immediately, pause or not")
        }
    }

    /// WHY: every exit from the sheet moves the quiz on, so a stale pause flag
    /// would mute the result screen's auto-advance and the next question's
    /// auto-confirm. Confirming IS resuming.
    @Test("confirming while paused clears the pause")
    func confirmWhilePausedResumes() async {
        await withMainSerialExecutor {
            let vm = makeSheetVM()
            vm.recordingCoordinator.pendingResponse = makePendingResponse()
            vm.pauseOnConfirmation()
            #expect(vm.isPaused)

            await vm.recordingCoordinator.confirmAnswer()

            #expect(vm.isPaused == false, "a confirmed answer must not leave the quiz paused")
            #expect(vm.showAnswerConfirmation == false)
        }
    }

    /// WHY (#131 Track D regression): the sheet pause and the result screen's
    /// STAY pill now share one flag. STAY must keep meaning only "don't
    /// auto-advance" — the driver still says "ďalej" to move on, so the command
    /// window has to stay open there.
    @Test("the result-screen STAY pill still only holds auto-advance")
    func resultStayKeepsListening() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeVM()
            vm.quizState = makeResultState()

            vm.pauseQuiz()

            #expect(vm.isPaused, "STAY sets the shared pause flag")
            #expect(
                vm.voiceCommandCoordinator.currentCommandScreen == .result,
                "STAY must not take the microphone — 'ďalej' has to keep working"
            )
            await vm.quizTimersController.startAutoAdvanceCountdown(duration: 8, audioDuration: 0)
            #expect(vm.autoAdvanceCountdown == 0, "auto-advance stays held while paused")
        }
    }
}
