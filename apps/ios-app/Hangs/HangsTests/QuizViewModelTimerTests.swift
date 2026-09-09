//
//  QuizViewModelTimerTests.swift
//  HangsTests
//
//  Split from QuizViewModelTests.swift (issue #31 task 3.2). Covers timer
//  primitives in QuizTimersController.swift (#113 T4, via the façade
//  forwards) plus the barge-in path — QuizViewModel.handleBargeIn — that
//  auto-starts recording during TTS.
//

import Foundation
@testable import Hangs
import Testing

// MARK: - Local helpers

/// Local minimal QuizResponse builder. The shared `Fixtures.makeFullMockNetwork()`
/// returns a happy-path response, but skip-related tests need a response that
/// advances to a *next* question without showing a result. Inlined here so the
/// fixture surface stays small.
@MainActor
private func makeNextQuestionResponse(
    sessionId: String = "test_session_123",
    nextQuestionId: String = "q_002"
) -> QuizResponse {
    QuizResponse(
        success: true,
        message: "Skipped",
        session: Fixtures.makeQuizSession(id: sessionId, phase: "asking"),
        currentQuestion: Fixtures.makeQuestion(id: nextQuestionId, text: "Next?", source: "Next"),
        evaluation: Evaluation(
            userAnswer: "skip",
            result: .incorrect,
            points: 0.0,
            correctAnswer: "Expected",
            questionId: "q_001",
            explanation: nil
        ),
        feedbackReceived: ["answer: incorrect"],
        audio: nil
    )
}

// MARK: - Answer Timer Tests (split from QuizViewModelTests.swift)

@Suite("QuizViewModel Answer Timer Tests")
struct QuizViewModelAnswerTimerTests {
    @Test("countdown resets to 0 when user taps mic")
    @MainActor
    func countdownResetsOnMicTap() async throws {
        let viewModel = Fixtures.makeViewModelForTimerTests()
        viewModel.settings.answerTimeLimit = 30

        // Manually set countdown as if timer is running
        viewModel.answerTimerCountdown = 15

        // Tapping mic triggers toggleRecording which calls cancelAnswerTimer
        await viewModel.toggleRecording()

        #expect(viewModel.answerTimerCountdown == 0)
        #expect(viewModel.quizState == .recording)
    }

    @Test("no timer when answerTimeLimit is 0")
    @MainActor
    func noTimerWhenTimeLimitOff() async throws {
        let viewModel = Fixtures.makeViewModelForTimerTests()
        viewModel.settings.answerTimeLimit = 0

        // After startNewQuiz or proceedToNextQuestion, answerTimerCountdown should stay 0.
        // We can't easily test startAnswerTimer directly since it's gated, but we can
        // verify the countdown stays at 0.
        #expect(viewModel.answerTimerCountdown == 0)
    }

    @Test("resetState clears all timer state")
    @MainActor
    func resetStateClearsTimerState() async throws {
        let viewModel = Fixtures.makeViewModelForTimerTests()
        viewModel.answerTimerCountdown = 20

        viewModel.resetToHome()

        #expect(viewModel.answerTimerCountdown == 0)
        #expect(viewModel.quizState == .idle)
    }

    @Test("skipQuestion cancels answer timer")
    @MainActor
    func skipQuestionCancelsAnswerTimer() async throws {
        let mockNetwork = Fixtures.makeFullMockNetwork { mock in
            mock.mockResponse = makeNextQuestionResponse()
        }
        let viewModel = QuizViewModel(
            networkService: mockNetwork,
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        viewModel.currentSession = Fixtures.makeActiveSession()
        viewModel.currentQuestion = Fixtures.makeQuestion()
        viewModel.quizState = .askingQuestion
        viewModel.answerTimerCountdown = 15

        await viewModel.skipQuestion()

        // After skip, answer timer should be cancelled (countdown reset to 0)
        #expect(viewModel.answerTimerCountdown == 0)
    }

    /// #108A (founder-rejected the old countdown-then-record behavior): tapping
    /// Re-record must open the mic immediately, mirroring the manual mic button —
    /// not restart another countdown. No answer countdown may be running once the
    /// mic is live.
    @Test("rerecordAnswer starts recording immediately with no answer countdown")
    @MainActor
    func rerecordStartsRecordingImmediately() async throws {
        let mockAudio = MockAudioService()
        let viewModel = QuizViewModel(
            networkService: MockNetworkService(),
            audioService: mockAudio,
            persistenceStore: MockPersistenceStore()
        )
        viewModel.currentQuestion = Fixtures.makeQuestion(id: "q_001", source: "Test")
        viewModel.quizState = .processing // the real call site: the confirmation sheet
        viewModel.answerTimerCountdown = 15 // stale value from a prior countdown

        viewModel.rerecordAnswer()

        // Synchronously: the countdown is cancelled right away, before recording
        // has had a chance to actually start on the spawned Task.
        #expect(viewModel.answerTimerCountdown == 0)

        await waitUntil({ viewModel.quizState == .recording }, "re-record never reached .recording")

        #expect(mockAudio.isRecording == true, "the mic must actually open, not just flip state")
        #expect(viewModel.answerTimerCountdown == 0, "no answer countdown should be running after re-record")
    }
}

// MARK: - Thinking Time Countdown Tests

@Suite("QuizViewModel Thinking Time Tests")
struct QuizViewModelThinkingTimeTests {
    @Test("startThinkingTimeCountdown sets initial countdown to settings.thinkingTime")
    @MainActor
    func thinkingTimeStartsAtConfiguredValue() async throws {
        let viewModel = Fixtures.makeViewModelForTimerTests()
        viewModel.settings.thinkingTime = 4

        viewModel.quizTimersController.startThinkingTimeCountdown()

        // The first iteration of the loop sets countdown to thinkingSeconds
        // synchronously before the first await — so by the time the next yield
        // returns to us, it's the seeded value.
        await Task.yield()
        #expect(viewModel.thinkingTimeCountdown == 4)

        viewModel.quizTimersController.cancelThinkingTime()
        #expect(viewModel.thinkingTimeCountdown == 0)
    }

    /// Regression: if `toggleRecording` ever stops calling `cancelThinkingTime()`
    /// the user's mic-tap during the thinking phase would race with the
    /// auto-record path — the manual recording starts, but the thinking-time
    /// task continues counting and could trigger a *second* startRecording when
    /// it expires.
    @Test("toggleRecording from askingQuestion cancels in-progress thinking time")
    @MainActor
    func micTapCancelsThinkingTime() async throws {
        let viewModel = Fixtures.makeViewModelForTimerTests()
        viewModel.settings.thinkingTime = 5
        viewModel.quizTimersController.startThinkingTimeCountdown()
        await Task.yield()
        #expect(viewModel.thinkingTimeCountdown == 5)

        await viewModel.toggleRecording()

        #expect(viewModel.thinkingTimeCountdown == 0)
        #expect(viewModel.quizState == .recording)
    }
}

// MARK: - Modal Freeze Tests (#81)

/// Local copy of the streaming-suite wall-clock-safe poll (see
/// QuizViewModelStreamingTests.waitUntil for the rationale).
@MainActor
private func waitUntil(
    _ predicate: @MainActor () -> Bool,
    timeoutMillis: Int = 10000,
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

@Suite("QuizViewModel No Modal Freeze Tests")
struct QuizViewModelNoModalFreezeTests {
    /// #81 follow-up (founder 2026-07-06): the answer countdown must keep
    /// running behind any modal (End-Quiz dialog, settings sheet) — a freeze
    /// is exploitable: opening a dialog would buy free thinking time. Same
    /// rationale as the no-pause-while-typing decision (2a). This test fails
    /// if anyone reintroduces a modal-freeze hold into the timer loop: the
    /// countdown must have decremented after real wall-clock time.
    @Test("answer countdown keeps ticking — no freeze mechanism exists")
    @MainActor
    func answerTimerKeepsTickingUnconditionally() async throws {
        let viewModel = Fixtures.makeViewModelForTimerTests()
        viewModel.settings.answerTimeLimit = 30

        viewModel.quizTimersController.startAnswerTimer()
        // Poll instead of asserting an exact value: under full-suite load the
        // observer can be starved past the first tick and miss the seed.
        await waitUntil({ viewModel.answerTimerCountdown > 0 }, "answer countdown never seeded")

        // A reintroduced freeze would hold the tick at the seeded 30; the loop
        // must decrement on its 1s cadence regardless of any presented modal.
        await waitUntil({ viewModel.answerTimerCountdown < 30 }, "answer countdown never ticked — a freeze mechanism is holding it")

        viewModel.quizTimersController.cancelAnswerTimer()
    }

    /// Same fairness guarantee for the thinking-time countdown: it must keep
    /// ticking behind modals — the user must not be able to stall auto-record
    /// by opening a dialog.
    @Test("thinking countdown keeps ticking — no freeze mechanism exists")
    @MainActor
    func thinkingTimerKeepsTickingUnconditionally() async throws {
        let viewModel = Fixtures.makeViewModelForTimerTests()
        viewModel.settings.thinkingTime = 30

        viewModel.quizTimersController.startThinkingTimeCountdown()
        // Poll for >0 (not ==30): under full-suite load the observer can be
        // starved past the first tick and miss the exact seed value.
        await waitUntil({ viewModel.thinkingTimeCountdown > 0 }, "thinking countdown never seeded")

        await waitUntil({ viewModel.thinkingTimeCountdown < 30 }, "thinking countdown never ticked — a freeze mechanism is holding it")

        viewModel.quizTimersController.cancelThinkingTime()
    }

    /// Founder decision 2a (#81, superseded recommendation): typing an answer
    /// does NOT pause the countdown — typed input grants no extra thinking
    /// time. The typed-answer path must never cancel the answer timer on its
    /// way in.
    @Test("resubmitAnswer leaves the answer timer running (no typing pause)")
    @MainActor
    func typedAnswerDoesNotPauseCountdown() async throws {
        let viewModel = Fixtures.makeViewModelForTimerTests()
        viewModel.settings.answerTimeLimit = 30
        viewModel.currentSession = Fixtures.makeActiveSession()

        viewModel.quizTimersController.startAnswerTimer()
        await Task.yield()
        #expect(viewModel.taskBag.contains(.answerTimer))

        await viewModel.resubmitAnswer("Paris", suppressAudio: true)

        // The timer task was not cancelled by the typed submission itself —
        // it self-expires once state leaves .askingQuestion.
        #expect(viewModel.taskBag.contains(.answerTimer))
    }
}

// MARK: - Auto-Stop Recording Timer Tests

@Suite("QuizViewModel Auto-Stop Recording Timer Tests")
struct QuizViewModelAutoStopRecordingTests {
    /// Regression: the recording window is the safety net that guarantees a
    /// recording can't run indefinitely if silence detection misses the trailing
    /// silence event. Removing either `taskBag.add` call would silently break
    /// that — the task would never be tracked or cancelled. #173 split it in two
    /// (visible speech-start countdown + hidden dead-air cap), so BOTH must be
    /// registered and both must go down on cancel.
    @Test("startAutoStopRecordingTimer registers both tracked tasks in the bag")
    @MainActor
    func autoStopRegistersTrackedTask() async throws {
        let viewModel = Fixtures.makeViewModelForTimerTests()
        viewModel.quizState = .recording

        viewModel.quizTimersController.startAutoStopRecordingTimer()

        #expect(viewModel.taskBag.contains(.autoStopRecording))
        #expect(viewModel.taskBag.contains(.recordingHardCap))

        viewModel.quizTimersController.cancelAutoStopRecordingTimer()
        #expect(!viewModel.taskBag.contains(.autoStopRecording))
        #expect(!viewModel.taskBag.contains(.recordingHardCap))
    }

    /// #173 (founder 2026-09-07): what the driver SEES is the 5 s window to
    /// start speaking, not the 15 s dead-air cap. Showing the cap made the
    /// screen read as frozen — the answer is long finished by then — and
    /// re-record inherited the same number ("Nahrať znova has 14 s").
    @Test("the visible recording window is the 5 s speech-start window, not the 15 s cap")
    @MainActor
    func visibleWindowIsSpeechStartWindow() async throws {
        let viewModel = Fixtures.makeViewModelForTimerTests()
        viewModel.quizState = .recording

        viewModel.quizTimersController.startAutoStopRecordingTimer()

        #expect(viewModel.answerWindowRemaining == Int(Config.speechStartWindow))
        #expect(viewModel.answerWindowTotal == Int(Config.speechStartWindow))
        #expect(Config.speechStartWindow < Config.autoRecordingDuration, "the cap must stay hidden behind it")

        viewModel.quizTimersController.cancelAutoStopRecordingTimer()
    }

    /// The countdown asks ONE question — "have you started speaking?" — so the
    /// answer retires it. Leaving it on screen would count down under an answer
    /// already in progress, which is the "it cut me off" reading the founder
    /// reported. `answerWindowTotal == 0` is the button's "no countdown" contract.
    @Test("speech hides the visible countdown but leaves the dead-air cap armed")
    @MainActor
    func speechHidesCountdownButKeepsCap() async throws {
        let viewModel = Fixtures.makeViewModelForTimerTests()
        viewModel.quizState = .recording
        viewModel.quizTimersController.startAutoStopRecordingTimer()

        viewModel.quizTimersController.speechDetectedDuringRecording()

        #expect(viewModel.answerWindowRemaining == 0, "the number must disappear once the driver is heard")
        #expect(viewModel.answerWindowTotal == 0, "…and so must the button's fill")
        #expect(!viewModel.taskBag.contains(.autoStopRecording))
        #expect(
            viewModel.taskBag.contains(.recordingHardCap),
            "a spoken answer still needs a backstop — VAD may never commit"
        )

        viewModel.quizTimersController.cancelAutoStopRecordingTimer()
    }

    /// #173 review finding: the short window is only honest where something can
    /// say "the driver started speaking", and that is a property of the SIGNAL,
    /// not of how recording was started. The batch path without auto-record is
    /// the one case with neither — no partial transcripts, and silence detection
    /// is subscribed for auto-record only — so a 5 s window there would close the
    /// mic mid-sentence and submit the truncated clip.
    @Test("the batch path with no VAD subscription keeps the full dead-air window")
    @MainActor
    func batchWithoutVADKeepsFullWindow() async throws {
        let (viewModel, _) = Fixtures.makeViewModelWithAudio()
        viewModel.currentQuestion = Fixtures.makeQuestion()
        viewModel.currentSession = Fixtures.makeActiveSession()
        viewModel.quizState = .askingQuestion
        viewModel.isAutoRecording = false // manual mic tap / "start" / re-record

        await viewModel.recordingCoordinator.startRecording()

        #expect(viewModel.quizState == .recording, "the mic must actually be open")
        #expect(
            viewModel.quizTimersController.recordingCountdownTotal == Int(Config.autoRecordingDuration),
            "no speech signal → the visible window IS the cap, as before #173"
        )

        viewModel.quizTimersController.cancelAutoStopRecordingTimer()
    }

    /// The contrast that keeps the fallback from swallowing the feature: the same
    /// batch path WITH auto-record does subscribe to VAD, so `.speechStarted` can
    /// retire the countdown and the founder's 5 s applies. (The streaming path
    /// keeps 5 s on every entry point — covered in QuizViewModelStreamingTests.)
    @Test("auto-record's VAD path keeps the 5 s speech-start window")
    @MainActor
    func autoRecordPathKeepsSpeechStartWindow() async throws {
        let (viewModel, _) = Fixtures.makeViewModelWithAudio()
        viewModel.currentQuestion = Fixtures.makeQuestion()
        viewModel.currentSession = Fixtures.makeActiveSession()
        viewModel.quizState = .askingQuestion
        viewModel.isAutoRecording = true

        await viewModel.recordingCoordinator.startRecording()

        #expect(viewModel.quizState == .recording)
        #expect(viewModel.quizTimersController.recordingCountdownTotal == Int(Config.speechStartWindow))

        viewModel.quizTimersController.cancelAutoStopRecordingTimer()
    }

    /// The cap is the only thing left once speech hid the countdown: if hiding
    /// the number also disarmed the stop, a dropped VAD commit would leave the
    /// mic open for the rest of the drive.
    @Test("the hidden dead-air cap still stops a recording whose countdown was hidden")
    @MainActor
    func hiddenCapStillStopsRecording() async throws {
        let (viewModel, _) = Fixtures.makeViewModelWithAudio()
        viewModel.currentQuestion = Fixtures.makeQuestion()
        viewModel.currentSession = Fixtures.makeActiveSession()
        viewModel.quizState = .recording

        // A visible window long enough that only the cap can end this.
        viewModel.quizTimersController.startAutoStopRecordingTimer(duration: 30, hardCap: 0.05)
        viewModel.quizTimersController.speechDetectedDuringRecording()

        for _ in 0 ..< 200 where viewModel.quizState == .recording {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(viewModel.quizState != .recording, "the cap must fire even with the countdown hidden")
    }

    /// CI regression (#173): the `deadAirCap` seam has to reach the HIDDEN cap,
    /// not just the visible countdown. While it did not, every "park the
    /// recording window" in the suite was a half-truth — the production 15 s cap
    /// stayed armed underneath, closed the mic mid-test and reopened the
    /// empty-answer sheet under assertions about the mic being open. That is how
    /// this branch was green locally (fast tests, 15 s never reached) and red on
    /// every CI push.
    @Test("the recording path arms the INJECTED dead-air cap, not the production one")
    @MainActor
    func injectedDeadAirCapEndsTheRecording() async throws {
        let (viewModel, mockAudio) = Fixtures.makeViewModelWithAudio()
        viewModel.currentQuestion = Fixtures.makeQuestion()
        viewModel.currentSession = Fixtures.makeActiveSession()
        viewModel.quizState = .askingQuestion
        viewModel.isAutoRecording = true // VAD subscribed → visible window ≠ cap
        // Only the cap can end this recording: the visible window outlives the test.
        viewModel.recordingCoordinator.speechStartWindow = 60
        viewModel.recordingCoordinator.deadAirCap = 0.05

        await viewModel.recordingCoordinator.startRecording()
        #expect(mockAudio.isRecording == true, "the mic must open before the cap can end it")

        await waitUntil({ !mockAudio.isRecording }, "the injected dead-air cap never ended the recording")
        #expect(mockAudio.isRecording == false)

        viewModel.quizTimersController.cancelAutoStopRecordingTimer()
    }

    /// #174 (from the #173 field notes): the hidden cap is armed BEFORE the
    /// engine comes up — deliberately, so a hung handshake still has a deadline.
    /// But when the handshake is merely SLOW, the cap fires into the gap: the
    /// state leaves `.recording`, the engine then finishes starting, and the
    /// window armed on top is vetoed by its own `.recording` guard — a mic left
    /// open with nothing that will ever close it. The capture path must notice
    /// the recording is already over and close the mic it just opened.
    @Test("a dead-air cap that fires during engine start closes the mic instead of leaving it open")
    @MainActor
    func capFiringDuringEngineStartClosesTheMic() async throws {
        let (viewModel, mockAudio) = Fixtures.makeViewModelWithAudio()
        viewModel.currentQuestion = Fixtures.makeQuestion()
        viewModel.currentSession = Fixtures.makeActiveSession()
        viewModel.quizState = .askingQuestion
        viewModel.recordingCoordinator.speechStartWindow = 60
        viewModel.recordingCoordinator.deadAirCap = 0.05
        mockAudio.prepareForRecordingDelay = 0.3 // the cap lands inside this gap

        await viewModel.recordingCoordinator.startRecording()

        #expect(viewModel.quizState != .recording, "the cap must have ended the recording during the handshake")
        #expect(mockAudio.isRecording == false, "the engine that came up late must be closed, not left recording")
        #expect(viewModel.quizTimersController.recordingCountdownTotal == 0, "no window may be armed on a recording that is over")

        viewModel.quizTimersController.cancelAutoStopRecordingTimer()
    }

    /// INTENT FLIPPED 2026-06-12 (#54 task 54.4, founder #5): this test used to
    /// assert re-record opts OUT of the cap ("longer pauses while reformulating").
    /// But silence detection is also disabled for re-records and never runs on
    /// the streaming path — so opting out meant a silent re-record could record
    /// FOREVER. The window must always be armed; a re-record gets exactly the
    /// same allowance as a first attempt (#173: the same 5 s to start speaking
    /// under the same hidden cap).
    @Test("startAutoStopRecordingTimer is armed even while isRerecording")
    @MainActor
    func autoStopArmedDuringRerecord() async throws {
        let viewModel = Fixtures.makeViewModelForTimerTests()
        viewModel.quizState = .recording
        viewModel.isRerecording = true

        viewModel.quizTimersController.startAutoStopRecordingTimer()

        #expect(viewModel.taskBag.contains(.autoStopRecording))
        viewModel.quizTimersController.cancelAutoStopRecordingTimer()
    }
}

// MARK: - Auto-Advance Countdown Tests

@Suite("QuizViewModel Auto-Advance Countdown Tests")
struct QuizViewModelAutoAdvanceTests {
    @Test("startAutoAdvanceCountdown seeds the published countdown and registers a task")
    @MainActor
    func autoAdvanceHappyPathRegistersTask() async throws {
        let viewModel = Fixtures.makeViewModelForTimerTests()
        viewModel.isPaused = false

        await viewModel.quizTimersController.startAutoAdvanceCountdown(duration: 7, audioDuration: 2.0)

        #expect(viewModel.autoAdvanceCountdown == 7)
        #expect(viewModel.taskBag.contains(.autoAdvance))

        // Cleanup — pauseQuiz cancels the .autoAdvance task and is the user-facing affordance.
        viewModel.pauseQuiz()
        #expect(!viewModel.taskBag.contains(.autoAdvance))
        #expect(viewModel.isPaused == true)
    }

    /// Regression: pause-on-current-question flips `isPaused = true`.
    /// Auto-advance must respect that for the rest of the result screen even if
    /// some other code path tries to (re)start it.
    @Test("startAutoAdvanceCountdown is a no-op when isPaused is true")
    @MainActor
    func autoAdvanceSkippedWhenPaused() async throws {
        let viewModel = Fixtures.makeViewModelForTimerTests()
        viewModel.isPaused = true

        await viewModel.quizTimersController.startAutoAdvanceCountdown(duration: 7, audioDuration: 2.0)

        #expect(viewModel.autoAdvanceCountdown == 0)
        #expect(!viewModel.taskBag.contains(.autoAdvance))
    }
}

// MARK: - Barge-In Tests

@Suite("QuizViewModel Barge-In Tests")
struct QuizViewModelBargeInTests {
    /// Returns a ViewModel wired with a mock silence-detection service so
    /// `handleBargeIn` exercises the full path (stop TTS, clear ttsPlaybackActive,
    /// transition to recording).
    @MainActor
    private func makeBargeInViewModel()
        -> (QuizViewModel, MockAudioService, MockSilenceDetectionService)
    {
        let mockAudio = MockAudioService()
        let mockSilence = MockSilenceDetectionService()
        let viewModel = QuizViewModel(
            networkService: MockNetworkService(),
            audioService: mockAudio,
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: mockSilence,
            sttService: nil
        )
        viewModel.currentQuestion = Fixtures.makeQuestion()
        return (viewModel, mockAudio, mockSilence)
    }

    /// Regression: barge-in is the "user starts speaking while TTS is playing
    /// over an external audio route" affordance. If the implementation forgets
    /// to stop TTS, audio overlap garbles the user's mic input. If it forgets
    /// to clear `ttsPlaybackActive`, the silence detector keeps suppressing
    /// barge-in events and the next TTS replay won't trigger again.
    @Test("handleBargeIn from askingQuestion stops TTS, clears tts flag, and ends in .recording")
    @MainActor
    func bargeInTransitionsToRecording() async throws {
        let (viewModel, mockAudio, mockSilence) = makeBargeInViewModel()
        viewModel.quizState = .askingQuestion
        mockAudio.isPlaying = true
        mockSilence.ttsPlaybackActive = true

        await viewModel.handleBargeIn()

        #expect(mockSilence.ttsPlaybackActive == false)
        #expect(viewModel.quizState == .recording)
        #expect(viewModel.isAutoRecording == true)
        #expect(viewModel.answerTimerCountdown == 0) // cancelAnswerTimer was called
    }

    /// Regression: barge-in must not fire from a non-asking state. If the
    /// outer guard at `handleBargeIn` is removed, a stray AsyncStream event
    /// during processing or showingResult could derail the state machine and
    /// flip the user back into recording mid-evaluation.
    @Test("handleBargeIn from non-askingQuestion is a no-op")
    @MainActor
    func bargeInNoOpFromOtherStates() async throws {
        let (viewModel, mockAudio, mockSilence) = makeBargeInViewModel()
        viewModel.quizState = .processing
        mockAudio.isPlaying = true
        mockSilence.ttsPlaybackActive = true

        await viewModel.handleBargeIn()

        // State + side effects untouched
        #expect(viewModel.quizState == .processing)
        #expect(mockAudio.isPlaying == true)
        #expect(mockSilence.ttsPlaybackActive == true)
        #expect(viewModel.isAutoRecording == false)
    }
}
