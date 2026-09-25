//
//  QuizViewModelStreamingTests.swift
//  HangsTests
//
//  Unit tests for the ElevenLabs streaming-STT path through QuizViewModel:
//  startRecording → startStreamingRecording → startSTTEventListener → handleCommittedTranscript
//
//  Uses withMainSerialExecutor (ConcurrencyExtras) to make Task scheduling
//  deterministic. Per audit A2-5: confirmation OUTSIDE, withMainSerialExecutor INSIDE.
//

import Clocks
import Foundation
import Testing
import ConcurrencyExtras
@testable import Hangs

// MARK: - Helpers

/// Returns a ViewModel + mocks ready for streaming-STT tests.
/// Session and question are pre-seeded; quizState is .askingQuestion so
/// startRecording() can fire immediately and route to startStreamingRecording().
@MainActor
private func makeViewModelWithSTT(clock: AnyClock<Duration> = AnyClock(TestClock()))
    -> (QuizViewModel, MockNetworkService, MockAudioService, MockElevenLabsSTTService) {
    let mockNetwork = Fixtures.makeFullMockNetwork()
    let mockAudio = MockAudioService()
    let mockPersistence = MockPersistenceStore()
    let mockSTT = MockElevenLabsSTTService()

    let viewModel = QuizViewModel(
        networkService: mockNetwork,
        audioService: mockAudio,
        persistenceStore: mockPersistence,
        silenceDetectionService: MockSilenceDetectionService(),
        sttService: mockSTT,
        clock: clock
    )

    // Seed the minimum state the streaming path needs.
    // currentSession.language is passed to sttService.connect(token:languageCode:).
    viewModel.currentSession = Fixtures.makeActiveSession()
    viewModel.currentQuestion = Fixtures.makeQuestion()
    viewModel.quizState = .askingQuestion

    return (viewModel, mockNetwork, mockAudio, mockSTT)
}

/// #180 track A: this file used to spin on a wall clock with real 1 ms sleeps
/// because tests 6/7 armed REAL timers and the rest could be starved by them
/// under a loaded parallel run. Both halves of that reason are gone: every
/// production timer here sleeps on the injected clock (parked by default in
/// `makeViewModelWithSTT`, advanced explicitly by the tests that are about a
/// timer), so the only thing left to wait for is task scheduling across the
/// actor → AsyncStream → listener Task → @MainActor handler hops. That is
/// exactly what the shared `pumpUntil` does, with no deadline to lose a race
/// to. `withMainSerialExecutor` keeps the interleaving deterministic.

/// Take the recording window out of these tests entirely.
///
/// #173 made the VISIBLE window 5 s ("time to start speaking"), and its expiry
/// really stops the mic and submits. The parked clock already means it cannot
/// fire under a test that is about the STT event pipeline; cancelling says so
/// explicitly, and keeps a once-a-second ticking task off the main actor the
/// whole parallel run shares. Tests that are ABOUT the window drive one.
@MainActor
private func parkRecordingWindow(_ viewModel: QuizViewModel) {
    viewModel.quizTimersController.cancelAutoStopRecordingTimer()
}

// MARK: - Suite

@Suite("QuizViewModel Streaming STT Tests")
@MainActor
struct QuizViewModelStreamingTests {

    // MARK: - Test 1: Happy connect

    /// Regression: prevents a refactor from skipping the WebSocket connect step or
    /// leaving isStreamingSTT=false after a successful connect, which would make the UI
    /// show a spinner instead of the live-transcript overlay while the user speaks.
    @Test("startRecording via streaming path sets isStreamingSTT=true and clears liveTranscript")
    func happyConnectSetsStreamingFlag() async throws {
        await withMainSerialExecutor {
            let (viewModel, _, _, _) = makeViewModelWithSTT()

            // startRecording() calls transition(.recording) then routes to startStreamingRecording()
            await viewModel.recordingCoordinator.startRecording()
            parkRecordingWindow(viewModel)
            await pumpUntil({ viewModel.isStreamingSTT }, "isStreamingSTT never flipped true")

            #expect(viewModel.isStreamingSTT == true)
            #expect(viewModel.liveTranscript == "")
            #expect(viewModel.quizState == .recording)
        }
    }

    // MARK: - Test 2: Partial transcript updates liveTranscript

    /// Regression: ensures partialTranscript events drive liveTranscript in real time.
    /// If the event-listener Task is accidentally cancelled early or the switch case is
    /// removed, live words silently disappear from the driving UI.
    @Test("partialTranscript event updates liveTranscript while state stays .recording")
    func partialTranscriptUpdatesLiveTranscript() async throws {
        await withMainSerialExecutor {
            let (viewModel, _, _, mockSTT) = makeViewModelWithSTT()

            await viewModel.recordingCoordinator.startRecording()
            parkRecordingWindow(viewModel)
            await pumpUntil({ viewModel.isStreamingSTT }, "streaming never started")

            await mockSTT.injectEvent(.partialTranscript("Par..."))
            await pumpUntil({ viewModel.liveTranscript == "Par..." }, "partial transcript never reached liveTranscript")

            #expect(viewModel.liveTranscript == "Par...")
            // A partial must never advance the state machine — only committed text does
            #expect(viewModel.quizState == .recording)
        }
    }

    // MARK: - Test 3: Committed transcript transitions to .processing

    /// Regression: if handleCommittedTranscript is accidentally disconnected from the
    /// event listener (e.g. wrong enum case), the user's final answer is silently lost
    /// and the confirmation sheet never appears.
    @Test("committedTranscript transitions to .processing and shows confirmation")
    func committedTranscriptTransitionsToProcessing() async throws {
        await withMainSerialExecutor {
            let (viewModel, _, _, mockSTT) = makeViewModelWithSTT()

            await viewModel.recordingCoordinator.startRecording()
            parkRecordingWindow(viewModel)
            await pumpUntil({ viewModel.isStreamingSTT }, "streaming never started")

            await mockSTT.injectEvent(.committedTranscript("Paris"))
            // handleCommittedTranscript transitions to .processing as its final step.
            await pumpUntil({ viewModel.quizState == .processing }, "never reached .processing")

            #expect(viewModel.transcribedAnswer == "Paris")
            #expect(viewModel.showAnswerConfirmation == true)
            #expect(viewModel.isStreamingSTT == false)
            #expect(viewModel.quizState == .processing)
        }
    }

    // MARK: - Test 4: Disconnected event clears streaming flags

    /// Regression: if the .disconnected case handler (Recording.swift:143-150) is removed
    /// or the isStreamingSTT guard is inverted, isStreamingSTT stays true after an
    /// unexpected WebSocket drop and the live-transcript overlay stays visible forever.
    @Test("disconnected event while streaming clears isStreamingSTT and liveTranscript")
    func disconnectedEventClearsStreamingFlags() async throws {
        await withMainSerialExecutor {
            let (viewModel, _, _, mockSTT) = makeViewModelWithSTT()

            await viewModel.recordingCoordinator.startRecording()
            parkRecordingWindow(viewModel)
            await pumpUntil({ viewModel.isStreamingSTT }, "streaming never started")

            // Establish a partial so we can verify liveTranscript is cleared too
            await mockSTT.injectEvent(.partialTranscript("Lon..."))
            await pumpUntil({ viewModel.liveTranscript == "Lon..." }, "partial never propagated")
            #expect(viewModel.isStreamingSTT == true)

            struct FakeNetworkError: Error {}
            await mockSTT.injectEvent(.disconnected(FakeNetworkError()))
            await pumpUntil({ !viewModel.isStreamingSTT }, "disconnected handler never ran")

            #expect(viewModel.isStreamingSTT == false)
            #expect(viewModel.liveTranscript == "")
            // 54.4 class: a drop mid-recording must not strand the UI in
            // .recording — the handler returns to ready-to-record.
            #expect(viewModel.quizState == .askingQuestion)
        }
    }

    // MARK: - Test 5: Empty committed transcript → prompt + one re-record (54.4 / #185 B)

    /// 54.4 (founder #5): dead air → forced commit returns "" — must never stay
    /// stuck in .recording. #185 track B (founder 1.1): the first miss is met
    /// with a spoken "didn't catch that" and a fresh STREAMING recording — the
    /// retry must reconnect the stream, not fall back or strand the driver.
    @Test("an empty committed transcript says so and re-opens the stream once")
    func emptyCommittedTranscriptRetriesOnce() async throws {
        await withMainSerialExecutor {
            let (viewModel, mockNetwork, mockAudio, mockSTT) = makeViewModelWithSTT()
            mockAudio.playbackDurationNs = 0

            await viewModel.recordingCoordinator.startRecording()
            parkRecordingWindow(viewModel)
            await pumpUntil({ viewModel.isStreamingSTT }, "streaming never started")
            let firstAttempt = viewModel.currentAttempt

            await mockSTT.injectEvent(.committedTranscript(""))
            await pumpUntil(
                { mockNetwork.synthesizedTexts.count == 1 && viewModel.isStreamingSTT && viewModel.quizState == .recording },
                "the miss never re-opened the stream"
            )

            #expect(mockNetwork.synthesizedTexts == [SpokenPrompt.didNotCatch.text(language: .english)])
            #expect(viewModel.currentAttempt != firstAttempt, "the retry is a new attempt of the same question")
            #expect(viewModel.showAnswerConfirmation == false)
            #expect(viewModel.errorMessage == nil, "no banner — the spoken line is the message")
        }
    }

    // MARK: - Test 6: Commit watchdog rescues a silent commit (54.4)

    /// 54.4: stopRecordingAndSubmit's streaming branch fires commitAndClose and
    /// waits for an event that may never come (dead air, dropped socket). The
    /// watchdog is the only thing stopping the UI from showing RECORDING forever.
    /// #171 Track B: its rescue is now the empty confirmation sheet — not a
    /// "didn't catch that" banner and a fresh countdown.
    @Test("commit watchdog escapes .recording onto the empty confirmation sheet")
    func commitWatchdogRescuesSilentCommit() async throws {
        await withMainSerialExecutor {
            let clock = TestClock()
            let (viewModel, _, _, mockSTT) = makeViewModelWithSTT(clock: AnyClock(clock))
            await mockSTT.setCommitEmitsNothing(true)

            // #185 track B: the automatic retry is spent — this test is about
            // the watchdog's terminal escape, the no-answer sheet.
            viewModel.recordingCoordinator.emptyAnswerRetryQuestionKey = viewModel.currentQuestion?.id

            await viewModel.recordingCoordinator.startRecording()
            parkRecordingWindow(viewModel)
            await pumpUntil({ viewModel.isStreamingSTT }, "streaming never started")

            await viewModel.recordingCoordinator.stopRecordingAndSubmit()
            #expect(viewModel.taskBag.contains(.sttCommitWatchdog), "watchdog not armed after commit")

            // The watchdog armed by the commit above IS the one under test now
            // (#180 track A): its SHIPPED timeout is driven on the clock, so no
            // re-arm with a shrunk one and no real second spent waiting.
            await clock.advance(by: .seconds(Config.sttCommitWatchdogSecs) - .milliseconds(100))
            #expect(viewModel.showAnswerConfirmation == false, "the watchdog must not rescue early")
            await clock.advance(by: .milliseconds(101)) // past it (integer ms: a fractional Duration can land short)
            await pumpUntil({ viewModel.showAnswerConfirmation }, "watchdog never rescued the stuck state")

            #expect(viewModel.quizState == .processing)
            #expect(viewModel.transcribedAnswer.isEmpty)
            #expect(viewModel.errorMessage == nil, "no retry banner — the empty sheet is the message")
            #expect(viewModel.isStreamingSTT == false)
            #expect(viewModel.taskBag.contains(.autoConfirm) == false, "#185 1.1: nothing counts this sheet down")
        }
    }

    // MARK: - Test 7: Hard cap fires on re-record too (54.4)

    /// 54.4: the cap was gated `guard !isRerecording` — a re-record with dead
    /// air had NO stop mechanism at all (silence detection is also disabled for
    /// re-records, and none runs on the streaming path).
    @Test("auto-stop hard cap is armed even when isRerecording is true")
    func autoStopCapFiresOnRerecord() async throws {
        await withMainSerialExecutor {
            let clock = TestClock()
            let (viewModel, _, _, _) = makeViewModelWithSTT(clock: AnyClock(clock))
            viewModel.isRerecording = true
            viewModel.quizState = .recording

            // The SHIPPED window, driven rather than shrunk (#180 track A).
            viewModel.quizTimersController.startAutoStopRecordingTimer()
            await clock.advance(by: .seconds(Config.speechStartWindow - 1))
            #expect(viewModel.quizState == .recording, "the window must not end a re-record early")
            await clock.advance(by: .seconds(1))
            await pumpUntil({ viewModel.quizState != .recording }, "cap never fired during re-record")

            #expect(viewModel.quizState != .recording)
        }
    }

    // MARK: - #173: the visible window counts the time to START speaking

    /// Founder 2026-09-07: the driver gets 5 s to start speaking, and the first
    /// content-bearing partial is the streaming path's ONLY speech signal (there
    /// is no local VAD there). It must retire the countdown — otherwise the
    /// number keeps draining under an answer already in progress and reads as
    /// "it is about to cut me off". The dead-air cap deliberately survives: the
    /// commit that ends a spoken answer may still never arrive.
    @Test("the first content-bearing partial transcript hides the countdown, not the cap")
    func partialTranscriptHidesSpeechStartCountdown() async throws {
        await withMainSerialExecutor {
            let (viewModel, _, _, mockSTT) = makeViewModelWithSTT()

            await viewModel.recordingCoordinator.startRecording()
            await pumpUntil({ viewModel.isStreamingSTT }, "streaming never started")

            // A window this test owns: what is under test is the partial
            // RETIRING it, not a wall-clock race with the real 5 s (the lengths
            // are pinned without any real timer in
            // QuizViewModelAutoStopRecordingTests).
            viewModel.quizTimersController.startAutoStopRecordingTimer(duration: 30, hardCap: 30)

            await mockSTT.injectEvent(.partialTranscript("bratislava"))
            await pumpUntil({ viewModel.answerWindowTotal == 0 }, "the countdown never retired on first speech")

            #expect(viewModel.answerWindowRemaining == 0)
            #expect(viewModel.recordingCoordinator.speechDetectedDuringAutoRecord)
            #expect(viewModel.taskBag.contains(.recordingHardCap), "the dead-air cap must outlive the countdown")
            #expect(viewModel.quizState == .recording, "hiding the number must not end the answer")
            viewModel.quizTimersController.cancelAutoStopRecordingTimer()
        }
    }

    /// An empty partial is the socket talking, not the driver: it must NOT count
    /// as speech, or the countdown would vanish while nothing has been said and
    /// the screen would go blank for the full 15 s cap.
    @Test("an empty partial transcript leaves the speech-start countdown running")
    func emptyPartialKeepsCountdownRunning() async throws {
        await withMainSerialExecutor {
            let (viewModel, _, _, mockSTT) = makeViewModelWithSTT()

            await viewModel.recordingCoordinator.startRecording()
            parkRecordingWindow(viewModel)
            await pumpUntil({ viewModel.isStreamingSTT }, "streaming never started")

            // A window this test owns: long enough that only the partial could
            // retire it, short enough not to keep ticking past the test.
            viewModel.quizTimersController.startAutoStopRecordingTimer(duration: 30, hardCap: 30)
            await mockSTT.injectEvent(.partialTranscript("   "))
            await Task.yield()

            #expect(viewModel.answerWindowTotal == 30, "an empty partial must not retire the window")
            #expect(viewModel.recordingCoordinator.speechDetectedDuringAutoRecord == false)
            viewModel.quizTimersController.cancelAutoStopRecordingTimer()
        }
    }

    /// Expiring with no speech must land where the 15 s cap always landed —
    /// forced commit → empty transcript → the no-answer path. Shortening the
    /// window must not have invented a new dead end for a driver who simply
    /// said nothing. (The #185 automatic retry is spent here: this test is about
    /// the window reaching the terminal Again/Skip sheet.)
    @Test("the speech-start window expiring with no speech ends on the empty-answer sheet")
    func speechStartExpiryEndsOnEmptySheet() async throws {
        await withMainSerialExecutor {
            let clock = TestClock()
            let (viewModel, _, _, mockSTT) = makeViewModelWithSTT(clock: AnyClock(clock))
            await mockSTT.setMockCommittedText("") // dead air: a forced commit returns nothing
            viewModel.recordingCoordinator.emptyAnswerRetryQuestionKey = viewModel.currentQuestion?.id

            // The production 5 s, driven on the clock (#180 track A): the
            // recording path arms it itself, so the expiry under test is the
            // REAL one and no wall-clock second is spent waiting for it.
            await viewModel.recordingCoordinator.startRecording()
            await pumpUntil({ viewModel.quizTimersController.recordingCountdownTotal > 0 },
                            "the mic never opened, so no speech-start window was armed")

            await clock.advance(by: .seconds(Config.speechStartWindow))
            await pumpUntil({ viewModel.showAnswerConfirmation }, "expiry never reached the confirmation sheet")

            #expect(viewModel.quizState == .processing)
            #expect(viewModel.transcribedAnswer.isEmpty)
            #expect(viewModel.noAnswerCaptured == true)
            #expect(viewModel.errorMessage == nil, "no retry banner — the empty sheet is the message")
        }
    }

    /// Founder finding 3: "Nahrať znova has 14 s". The decision is 5 s for the
    /// first recording AND for re-record, and production STT is this streaming
    /// path — partial transcripts arrive however recording began, so re-record
    /// must NOT be widened to the cap along with the signal-less batch branch.
    /// A second, longer window here would be the original complaint, unfixed.
    @Test("re-record arms the same speech-start window as the first attempt")
    func rerecordUsesTheSameSpeechStartWindow() async throws {
        await withMainSerialExecutor {
            let (viewModel, _, mockAudio, _) = makeViewModelWithSTT()
            viewModel.quizState = .processing
            viewModel.showAnswerConfirmation = true
            viewModel.transcribedAnswer = "misheard answer"

            // Read the window at the FIRST moment the mic is OPEN — which is
            // `mockAudio.isRecording`, not `.recording`. #173 arms the window
            // when the engine comes up rather than when we start asking for it,
            // and the state flips first: waiting on the state reads the window
            // mid-handshake, before there is one, and blames the arming (CI:
            // `armedWindow → 0`).
            var armedWindow: Int?
            viewModel.recordingCoordinator.rerecordAnswer()
            await pumpUntil({
                guard mockAudio.isRecording else { return false }
                if armedWindow == nil {
                    armedWindow = viewModel.quizTimersController.recordingCountdownTotal
                }
                return true
            }, "re-record never reopened the mic")

            #expect(armedWindow == Int(Config.speechStartWindow))
        }
    }

    // MARK: - Test 8: MCQ voice match survives the listener's self-cancel (54.5 class)

    /// Regression: handleCommittedTranscript runs inside the .sttEvent listener
    /// task and cancels that very task before routing. The confirmation it opens
    /// must survive that self-cancel — without care the routing inherits
    /// the cancellation and throws URLError(.cancelled): the driver says the
    /// right answer and gets the OOPS screen. The direct-call tests in
    /// QuizViewModelMCQVoiceTests can't catch this (no enclosing cancelled
    /// task), so this drives the committed transcript through the real event
    /// stream. Found live in the 54.16 in-sim verify, 2026-06-13.
    @Test("MCQ voice match through the event stream reaches the confirmation sheet, then submits")
    func mcqVoiceMatchSubmitsThroughEventStream() async throws {
        await withMainSerialExecutor {
            let (viewModel, mockNetwork, _, mockSTT) = makeViewModelWithSTT()
            viewModel.currentQuestion = Question(
                id: "q_mcq_001",
                question: "Largest planet?",
                type: .textMultichoice,
                possibleAnswers: ["a": "Mars", "b": "Jupiter", "c": "Venus", "d": "Saturn"],
                difficulty: "medium",
                topic: "Astronomy",
                category: "science",
                sourceUrl: nil,
                sourceExcerpt: nil,
                mediaUrl: nil,
                imageSubtype: nil,
                explanation: nil,
                generatedBy: nil
            )

            await viewModel.recordingCoordinator.startRecording()
            parkRecordingWindow(viewModel)
            await pumpUntil({ viewModel.isStreamingSTT }, "streaming never started")

            await mockSTT.injectEvent(.committedTranscript("Jupiter"))
            // #171 Track I: the match opens the sheet instead of submitting.
            await pumpUntil({ viewModel.showAnswerConfirmation }, "voice match never reached the confirmation sheet")
            #expect(mockNetwork.capturedTextInputInput == nil)
            #expect(viewModel.transcribedAnswer == "Jupiter")

            await viewModel.confirmAnswer()
            await pumpUntil({ viewModel.quizState.isShowingResult }, "confirmed voice-match submit never completed")

            #expect(mockNetwork.capturedTextInputInput == "Jupiter")
            #expect(viewModel.mcqVoiceMatchedKey == "b")
            #expect(viewModel.errorMessage == nil)
        }
    }
}
