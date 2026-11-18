//
//  SilentReadingPauseTests.swift
//  HangsTests
//
//  #208 (TF test 2026-10-16), two findings on the question screen:
//   1. The bar said "Reading the question" whenever no think window ran, also
//      when nothing was being read (muted, a question without audio, right
//      after a skip). "Reading" may only show while a read really plays.
//   2. Founder decision 2026-10-16: with read-aloud muted (or no clip) the
//      driver reads the question off the screen, so the think countdown stands
//      still at full for a silent reading pause (words / 2.5 s, 3 s to 15 s)
//      and only then drains.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@Suite("Silent reading pause and the honest reading label (#208)")
@MainActor
struct SilentReadingPauseTests {
    private static let questionAudio = "https://example.invalid/q.opus"
    /// 20 words → 8 s of silent reading.
    private static let twentyWords = Array(repeating: "word", count: 20).joined(separator: " ")

    private func makeVM(
        clock: TestClock<Duration>,
        network: MockNetworkService = Fixtures.makeFullMockNetwork(),
        text: String = twentyWords
    ) -> (QuizViewModel, MockAudioService) {
        let audio = MockAudioService()
        audio.playbackDurationNs = 0
        let vm = QuizViewModel(
            networkService: network,
            audioService: audio,
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService(),
            clock: AnyClock(clock)
        )
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Fixtures.makeQuestion(text: text)
        vm.quizState = .askingQuestion
        vm.settings.thinkingTime = 10
        return (vm, audio)
    }

    private func drain() async {
        for _ in 0 ..< 20 {
            await Task.yield()
        }
    }

    // MARK: - The pause length

    /// WHY: the founder's rule is deterministic from the text, so the same
    /// question always gives the same time, and the clamps keep a one-liner
    /// from flashing past and a long MCQ stem from stalling the quiz.
    @Test("the pause is words / 2.5 s, clamped to 3 s … 15 s")
    func pauseLengthFollowsTheWords() {
        #expect(QuizTimersController.silentReadingPause(for: "What is 2+2?") == .seconds(3), "short: the 3 s floor")
        #expect(QuizTimersController.silentReadingPause(for: Self.twentyWords) == .seconds(8))
        let long = Array(repeating: "word", count: 100).joined(separator: " ")
        #expect(QuizTimersController.silentReadingPause(for: long) == .seconds(15), "long: the 15 s cap")
        #expect(QuizTimersController.silentReadingPause(for: "") == .seconds(3))
    }

    // MARK: - Muted read

    /// WHY: the finding itself. Muted, the countdown used to start draining the
    /// moment the question appeared, eating the time the driver needs to read
    /// it. During the pause the number is full and still, and the bar shows the
    /// think state, never "Reading the question" (nothing reads).
    @Test("muted: the countdown stands full for the reading pause, then drains")
    func mutedQuestionWaitsTheReadingPause() async throws {
        let clock = TestClock()
        let (vm, audio) = makeVM(clock: clock)
        let question = try #require(vm.currentQuestion)
        vm.settings.isMuted = true

        await vm.audioDeviceState.playQuestionAudio(from: Self.questionAudio)
        await drain()

        #expect(audio.playOpusCallCount == 0, "muted means nothing plays")
        #expect(vm.listenPhase(for: question) == .thinking(remaining: 10, total: 10))
        await clock.advance(by: .seconds(7))
        #expect(vm.thinkingTimeCountdown == 10, "still within the 8 s pause: full and not moving")

        await clock.advance(by: .seconds(1))
        await drain()
        await clock.advance(by: .seconds(1))
        await pumpUntil({ vm.thinkingTimeCountdown == 9 }, "after the pause the window drains as usual")
        vm.quizTimersController.cancelThinkingTime()
    }

    /// WHY: the voice-commands half of the decision. A driver who has read the
    /// question in 2 s can still say "start" — the pause must not hold the mic
    /// shut, so the command window is open while it runs.
    @Test("muted: voice commands are live during the reading pause")
    func commandsAreLiveDuringThePause() async throws {
        let clock = TestClock()
        let (vm, _) = makeVM(clock: clock)
        vm.settings.isMuted = true

        await vm.audioDeviceState.playQuestionAudio(from: Self.questionAudio)
        await drain()

        #expect(vm.voiceCommandCoordinator.currentCommandScreen == .question)
        vm.quizTimersController.cancelThinkingTime()
    }

    // MARK: - No audio

    /// WHY: a question that came without a clip is read off the screen just
    /// like a muted one, so it gets the same pause.
    @Test("no clip: the same reading pause before the window drains")
    func questionWithoutAudioWaitsTheReadingPause() async throws {
        let clock = TestClock()
        let (vm, _) = makeVM(clock: clock)

        vm.startRecordingOrTimer(afterSilentRead: true)
        await drain()

        #expect(vm.thinkingTimeCountdown == 10)
        await clock.advance(by: .seconds(7))
        #expect(vm.thinkingTimeCountdown == 10, "still the reading pause")
        await clock.advance(by: .seconds(2))
        await pumpUntil { vm.thinkingTimeCountdown == 9 }
        vm.quizTimersController.cancelThinkingTime()
    }

    /// WHY: a question the driver left (skipped, answered by tap) must never
    /// open the mic when its reading pause ends.
    @Test("leaving the question during the pause never auto-records")
    func pauseEndsWithTheQuestion() async throws {
        let clock = TestClock()
        let (vm, _) = makeVM(clock: clock)

        vm.startRecordingOrTimer(afterSilentRead: true)
        await drain()
        vm.quizTimersController.cancelThinkingTime() // what skip / a tap answer does
        vm.quizState = .idle

        await clock.advance(by: .seconds(30))
        await drain()

        #expect(vm.isAutoRecording == false)
        #expect(vm.thinkingTimeCountdown == 0)
    }

    /// WHY: pause means frozen (#200). A pause inside the reading pause keeps
    /// the full window on screen; play continues with that window, not a mic.
    @Test("a quiz pause during the reading pause holds the full window")
    func quizPauseDuringReadingPause() async throws {
        let clock = TestClock()
        let (vm, _) = makeVM(clock: clock)
        let question = try #require(vm.currentQuestion)

        vm.startRecordingOrTimer(afterSilentRead: true)
        await drain()
        vm.togglePause()
        await clock.advance(by: .seconds(60))
        await drain()

        #expect(vm.listenPhase(for: question) == .thinking(remaining: 10, total: 10))
        #expect(vm.isAutoRecording == false, "paused: nothing opens the mic")

        vm.togglePause()
        await clock.advance(by: .seconds(1))
        await pumpUntil({ vm.thinkingTimeCountdown == 9 }, "play continues with the window")
        vm.quizTimersController.cancelThinkingTime()
    }

    // MARK: - The reading label

    /// WHY: "Reading the question" is a promise that something speaks. Without
    /// a read and without a window (a retry bridge, a no-think-time setting),
    /// the bar shows the plain command bar instead.
    @Test("no read and no window is not reading")
    func noReadIsNotReading() throws {
        let clock = TestClock()
        let (vm, _) = makeVM(clock: clock)
        let question = try #require(vm.currentQuestion)

        #expect(vm.listenPhase(for: question) == .thinking(remaining: 0, total: 0))

        vm.isPlayingQuestionTTS = true
        #expect(vm.listenPhase(for: question) == .readingQuestion, "a playing read is reading")
    }

    /// WHY: the exact TF repro. Skip, then the next question while muted: the
    /// bar showed "Reading the question" over a silent screen.
    @Test("skip → next question while muted never shows the reading label")
    func skipToNextQuestionWhileMuted() async throws {
        let clock = TestClock()
        let network = Fixtures.makeFullMockNetwork { mock in
            mock.mockResponse = QuizResponse(
                success: true,
                message: "Skipped",
                session: Fixtures.makeQuizSession(id: "test_session_123", phase: "asking"),
                currentQuestion: Fixtures.makeQuestion(id: "q_002", text: Self.twentyWords),
                evaluation: Evaluation(
                    userAnswer: "skip", result: .skipped, points: 0,
                    correctAnswer: "4", questionId: "q_001", explanation: nil
                ),
                feedbackReceived: [],
                audio: AudioInfo(feedbackUrl: nil, feedbackAudioBase64: nil, questionUrl: Self.questionAudio, format: "opus")
            )
        }
        let (vm, audio) = makeVM(clock: clock, network: network, text: "What is 2+2?")
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001", text: "What is 2+2?")
        vm.settings.isMuted = true

        await vm.skipQuestion()
        guard case .showingResult = vm.quizState else {
            Issue.record("the skip must land on the result screen, got \(vm.quizState)")
            return
        }
        await vm.proceedToNextQuestion()
        await drain()

        let next = try #require(vm.currentQuestion)
        #expect(next.id == "q_002")
        #expect(vm.quizState == .askingQuestion)
        #expect(audio.playOpusCallCount == 0)
        #expect(vm.listenPhase(for: next) != .readingQuestion)
        #expect(vm.listenPhase(for: next) == .thinking(remaining: 10, total: 10), "the reading pause, full and still")
        vm.quizTimersController.cancelThinkingTime()
    }
}
