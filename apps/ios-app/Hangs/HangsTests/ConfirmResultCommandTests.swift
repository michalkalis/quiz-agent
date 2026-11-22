//
//  ConfirmResultCommandTests.swift
//  HangsTests
//
//  Issue #77 (voice commands hands-free), task 77.9 — the confirm / result / repeat
//  / skip command wiring. Drives `handleRecognizedCommand` directly (routing seam).
//  Covers:
//    • Confirmation sheet: "again" → rerecordAnswer, ON TOP of the auto-confirm
//      + buttons (the spoken confirm / stop-hold words are gone, 2026-11-22);
//    • the 10 s auto-confirm still fires with NO speech (regression guard);
//    • Result: no command window, a stray command is inert;
//    • Question: "repeat" replays the question audio + re-arms the listener;
//    • Question: "next" skips at once (the undo-window is gone, 2026-11-22).
//

import Clocks
import ConcurrencyExtras
import Foundation
@testable import Hangs
import SwiftUI
import Testing

@MainActor
private func makeVM(clock: AnyClock<Duration> = .continuous) -> (QuizViewModel, MockSilenceDetectionService, MockAudioService) {
    let audio = MockAudioService()
    let silence = MockSilenceDetectionService()
    let vm = QuizViewModel(
        networkService: Fixtures.makeFullMockNetwork(),
        audioService: audio,
        persistenceStore: MockPersistenceStore(),
        silenceDetectionService: silence,
        clock: clock
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

/// #180 track A: the only waits left here that need real time are the ones
/// behind a sanctioned audio hardware settle (`proceedToNextQuestion`'s
/// deliberate `Task.sleep` and the audio mock's 0.1 s playback) — a
/// scheduler-turn pump cannot outlast those. Every other wait in this file is
/// `pumpUntil`, which has no wall clock to lose a race to.
@MainActor
private func waitForAudioSettle(
    _ predicate: @MainActor () -> Bool,
    timeoutMillis: Int = 15000,
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
    Issue.record(comment ?? "audio-settle wait timed out after \(timeoutMillis)ms", sourceLocation: sourceLocation)
}

@Suite("Confirm / Result / Repeat / Skip command wiring (77.9)")
@MainActor
struct ConfirmResultCommandTests {
    // MARK: - Confirmation sheet

    @Test("'again' on the confirmation sheet re-records immediately (#108A)")
    func againReRecords() async {
        await withMainSerialExecutor {
            let (vm, _, audio) = makeVM()
            vm.quizState = .processing
            vm.showAnswerConfirmation = true
            vm.recordingCoordinator.pendingResponse = makePendingResponse()
            // #173 seam: this test is about the mic opening, not about the
            // recording window — give it one that cannot expire mid-test and
            // reopen the empty-answer sheet under the assertions below.
            vm.recordingCoordinator.speechStartWindow = 60
            vm.recordingCoordinator.deadAirCap = 60

            vm.voiceCommandCoordinator.handleRecognizedCommand(.again)

            for _ in 0 ..< 40 {
                await Task.yield()
            }
            #expect(vm.showAnswerConfirmation == false)
            #expect(vm.isRerecording == true)
            // Founder-rejected the old countdown-then-record behavior: "again"
            // must open the mic right away, not park on askingQuestion.
            #expect(vm.quizState == .recording, "re-record must start recording immediately")
            #expect(vm.isAnswerCaptureActive == true) // #184: capture on the shared engine
            _ = audio
            vm.quizTimersController.cancelAutoStopRecordingTimer()
        }
    }

    @Test("the 10 s auto-confirm still fires with NO speech (unchanged fallback)")
    func autoConfirmStillFires() async {
        await withMainSerialExecutor {
            // #180 track A: the SHIPPED delay, driven on a TestClock — the old
            // shrunk 1 s raced real time and was starved under parallel load.
            let clock = TestClock()
            let (vm, _, _) = makeVM(clock: AnyClock(clock))
            vm.quizState = .processing
            vm.showAnswerConfirmation = true
            vm.recordingCoordinator.pendingResponse = makePendingResponse()
            vm.settings.autoConfirmEnabled = true

            // No spoken command — the auto-confirm timer alone must confirm.
            vm.quizTimersController.startAutoConfirmIfEnabled()
            await pumpUntil { vm.autoConfirmCountdown == Config.autoConfirmDelaySecs }

            await clock.advance(by: .seconds(Config.autoConfirmDelaySecs - 1))
            #expect(vm.showAnswerConfirmation == true, "the sheet may not confirm before the delay is up")

            await clock.advance(by: .seconds(1))
            await pumpUntil({ !vm.showAnswerConfirmation }, "auto-confirm did not fire with no speech")
            #expect(vm.showAnswerConfirmation == false)
        }
    }

    // MARK: - Result

    /// WHY (#224, founder TF 2026-11-02): the result is read with a button and
    /// the auto-advance countdown; a listener there only confused. A spoken
    /// "next" / "again" must find no window and leave the result where it is.
    @Test("the result screen has no command window, so a stray command is inert")
    func resultHasNoCommandWindow() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeVM()
            vm.quizState = makeResultState()
            #expect(vm.voiceCommandCoordinator.currentCommandScreen == nil)

            vm.voiceCommandCoordinator.handleRecognizedCommand(.next)
            vm.voiceCommandCoordinator.handleRecognizedCommand(.again)

            guard case .showingResult = vm.quizState else {
                Issue.record("a command advanced the result screen")
                return
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
            await waitForAudioSettle({ audio.playOpusCallCount >= 1 }, "repeat did not replay the question")
            await waitForAudioSettle({ !vm.isPlayingQuestionTTS && silence.isListening },
                                     "listener was not re-armed after replay")
            #expect(audio.playOpusCallCount >= 1)
            #expect(silence.isListening == true)
        }
    }

    // MARK: - Skip

    /// WHY (founder 2026-11-22): the 2.5 s undo wait made "next" feel broken.
    /// The routed command skips at once; with the quiz clock parked, a skip
    /// that still waited on a timer would never leave the question.
    @Test("'next' on the question screen skips at once, with no undo wait")
    func nextSkipsAtOnce() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeVM(clock: AnyClock(TestClock()))
            vm.quizState = .askingQuestion

            vm.voiceCommandCoordinator.handleRecognizedCommand(.next)

            await pumpUntil({ vm.quizState != .askingQuestion }, "'next' did not skip the question")
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

    /// WHY: resuming must hand back the FULL window. Restarting from whatever
    /// was left when the driver paused would silently shorten the only chance
    /// they have to correct a mis-transcription.
    @Test("Continue re-arms a full 5 s window and re-opens the command window")
    func resumeReArmsTheFullWindow() async {
        await withMainSerialExecutor {
            let vm = makeSheetVM()
            vm.enterPause()
            #expect(vm.autoConfirmCountdown == 0)

            vm.exitPause()

            #expect(vm.isPaused == false)
            // #185 5.2: the window re-arms once the listener is live again.
            await pumpUntil({ vm.autoConfirmCountdown == Config.autoConfirmDelaySecs }, "resume never re-armed")
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
            vm.enterPause()

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
            vm.recordingCoordinator.speechStartWindow = 60 // see the #173 seam note above
            vm.recordingCoordinator.deadAirCap = 60
            vm.enterPause()
            #expect(vm.isPaused)

            vm.recordingCoordinator.rerecordAnswer()

            for _ in 0 ..< 40 {
                await Task.yield()
            }
            #expect(vm.isPaused == false, "re-record must not leave the quiz paused")
            #expect(vm.showAnswerConfirmation == false)
            #expect(vm.quizState == .recording, "re-record opens the mic immediately, pause or not")
            vm.quizTimersController.cancelAutoStopRecordingTimer()
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
            vm.enterPause()
            #expect(vm.isPaused)

            await vm.recordingCoordinator.confirmAnswer()

            #expect(vm.isPaused == false, "a confirmed answer must not leave the quiz paused")
            #expect(vm.showAnswerConfirmation == false)
        }
    }

    /// WHY (#131 Track D regression): the sheet pause and the result screen's
    /// STAY pill share one flag. STAY must keep meaning only "don't
    /// auto-advance"; it never touches the microphone (the result has none, #224).
    @Test("the result-screen STAY pill still only holds auto-advance")
    func resultStayKeepsListening() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeVM()
            vm.quizState = makeResultState()

            vm.pauseQuiz()

            #expect(vm.isPaused, "STAY sets the shared pause flag")
            #expect(vm.voiceCommandCoordinator.currentCommandScreen == nil, "the result never listens")
            await vm.quizTimersController.startAutoAdvanceCountdown(duration: 8, audioDuration: 0)
            #expect(vm.autoAdvanceCountdown == 0, "auto-advance stays held while paused")
        }
    }
}
