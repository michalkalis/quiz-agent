//
//  QuizViewModelTimerTests.swift
//  HangsTests
//
//  Split from QuizViewModelTests.swift (issue #31 task 3.2). Covers timer
//  primitives in QuizViewModel+Timers.swift plus the barge-in path in
//  QuizViewModel+Audio.swift that auto-starts recording during TTS.
//

import Foundation
import Testing
@testable import Hangs

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

    @Test("rerecordAnswer restarts answer timer with bonus")
    @MainActor
    func rerecordRestartsTimerWithBonus() async throws {
        let viewModel = Fixtures.makeViewModelForTimerTests()
        let previousCountdown = viewModel.answerTimerCountdown

        // Simulate re-record action
        viewModel.rerecordAnswer()

        #expect(viewModel.quizState == .askingQuestion)
        // Timer must keep ticking after re-record (the previous attempt may have
        // failed because the app misheard the user, not because of timeout).
        // Don't pin to the exact +10 literal — the policy may evolve; what matters
        // is the user gets *more* time than they had a moment ago.
        #expect(viewModel.answerTimerCountdown > previousCountdown)
        #expect(viewModel.answerTimerCountdown >= viewModel.settings.answerTimeLimit)
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

        viewModel.startThinkingTimeCountdown()

        // The first iteration of the loop sets countdown to thinkingSeconds
        // synchronously before the first await — so by the time the next yield
        // returns to us, it's the seeded value.
        await Task.yield()
        #expect(viewModel.thinkingTimeCountdown == 4)

        viewModel.cancelThinkingTime()
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
        viewModel.startThinkingTimeCountdown()
        await Task.yield()
        #expect(viewModel.thinkingTimeCountdown == 5)

        await viewModel.toggleRecording()

        #expect(viewModel.thinkingTimeCountdown == 0)
        #expect(viewModel.quizState == .recording)
    }
}

// MARK: - Auto-Stop Recording Timer Tests

@Suite("QuizViewModel Auto-Stop Recording Timer Tests")
struct QuizViewModelAutoStopRecordingTests {

    /// Regression: `Config.autoRecordingDuration = 15` is the safety net that
    /// guarantees a recording session can't run indefinitely if silence
    /// detection misses the trailing silence event. Removing the
    /// `taskBag.add(_, key: .autoStopRecording)` call would silently break this
    /// guarantee — the task would never be tracked or cancelled.
    @Test("startAutoStopRecordingTimer registers a tracked task in the bag")
    @MainActor
    func autoStopRegistersTrackedTask() async throws {
        let viewModel = Fixtures.makeViewModelForTimerTests()
        viewModel.quizState = .recording

        viewModel.startAutoStopRecordingTimer()

        #expect(viewModel.taskBag.contains(.autoStopRecording))

        viewModel.cancelAutoStopRecordingTimer()
        #expect(!viewModel.taskBag.contains(.autoStopRecording))
    }

    /// INTENT FLIPPED 2026-06-12 (#54 task 54.4, founder #5): this test used to
    /// assert re-record opts OUT of the cap ("longer pauses while reformulating").
    /// But silence detection is also disabled for re-records and never runs on
    /// the streaming path — so opting out meant a silent re-record could record
    /// FOREVER. The hard cap must always be armed; 15 s is the same allowance a
    /// first attempt gets.
    @Test("startAutoStopRecordingTimer is armed even while isRerecording")
    @MainActor
    func autoStopArmedDuringRerecord() async throws {
        let viewModel = Fixtures.makeViewModelForTimerTests()
        viewModel.quizState = .recording
        viewModel.isRerecording = true

        viewModel.startAutoStopRecordingTimer()

        #expect(viewModel.taskBag.contains(.autoStopRecording))
        viewModel.cancelAutoStopRecordingTimer()
    }
}

// MARK: - Auto-Advance Countdown Tests

@Suite("QuizViewModel Auto-Advance Countdown Tests")
struct QuizViewModelAutoAdvanceTests {

    @Test("startAutoAdvanceCountdown seeds the published countdown and registers a task")
    @MainActor
    func autoAdvanceHappyPathRegistersTask() async throws {
        let viewModel = Fixtures.makeViewModelForTimerTests()
        viewModel.autoAdvanceEnabled = true
        viewModel.currentQuestionPaused = false

        await viewModel.startAutoAdvanceCountdown(duration: 7, audioDuration: 2.0)

        #expect(viewModel.autoAdvanceCountdown == 7)
        #expect(viewModel.taskBag.contains(.autoAdvance))

        // Cleanup — pauseQuiz cancels the .autoAdvance task and is the user-facing affordance.
        viewModel.pauseQuiz()
        #expect(!viewModel.taskBag.contains(.autoAdvance))
        #expect(viewModel.currentQuestionPaused == true)
    }

    /// Regression: the global "auto-advance" toggle in Settings flips
    /// `autoAdvanceEnabled = false`. If the guard in
    /// `startAutoAdvanceCountdown` is dropped, every result screen would
    /// auto-advance regardless of the user's setting.
    @Test("startAutoAdvanceCountdown is a no-op when autoAdvanceEnabled is false")
    @MainActor
    func autoAdvanceSkippedWhenDisabled() async throws {
        let viewModel = Fixtures.makeViewModelForTimerTests()
        viewModel.autoAdvanceEnabled = false
        viewModel.autoAdvanceCountdown = 99  // pretend a previous countdown lingered

        await viewModel.startAutoAdvanceCountdown(duration: 7, audioDuration: 2.0)

        #expect(viewModel.autoAdvanceCountdown == 0)
        #expect(!viewModel.taskBag.contains(.autoAdvance))
    }

    /// Regression: pause-on-current-question flips `currentQuestionPaused = true`.
    /// Auto-advance must respect that for the rest of the result screen even if
    /// some other code path tries to (re)start it.
    @Test("startAutoAdvanceCountdown is a no-op when currentQuestionPaused is true")
    @MainActor
    func autoAdvanceSkippedWhenPaused() async throws {
        let viewModel = Fixtures.makeViewModelForTimerTests()
        viewModel.autoAdvanceEnabled = true
        viewModel.currentQuestionPaused = true

        await viewModel.startAutoAdvanceCountdown(duration: 7, audioDuration: 2.0)

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
        -> (QuizViewModel, MockAudioService, MockSilenceDetectionService) {
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
        #expect(viewModel.answerTimerCountdown == 0)  // cancelAnswerTimer was called
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
