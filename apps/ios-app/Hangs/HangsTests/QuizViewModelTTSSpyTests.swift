//
//  QuizViewModelTTSSpyTests.swift
//  HangsTests
//
//  RS-11 / issue #59.1 — "Question is not read aloud (TTS silent)".
//
//  The whole AVFoundation stack is replaced by MockAudioService in tests, so the
//  only way to prove "TTS was actually attempted on askingQuestion" is the spy
//  counters added to the mock (playOpusCallCount / lastPlayedData). These tests
//  pin two invariants that the green-but-broken suite never checked:
//    1. asking a question drives exactly one TTS playback attempt;
//    2. a TTS *failure* is swallowed (the quiz is not stranded) AND TTS is
//       re-attempted on the next question.
//
//  Branch under test: QuizViewModel+Audio.swift playQuestionAudio(from:).
//

import Foundation
import Testing
@testable import Hangs

// MARK: - Local helper

/// A ViewModel in `askingQuestion` with a controllable audio mock and a network
/// mock that returns audio bytes for `downloadAudio`. Returns both mocks so tests
/// can inject playback failure and read the TTS spy.
@MainActor
private func makeAskingViewModel(
    failPlayback: Bool = false
) -> (QuizViewModel, MockAudioService) {
    let mockAudio = MockAudioService()
    mockAudio.shouldFailPlayback = failPlayback
    let mockNetwork = Fixtures.makeFullMockNetwork()
    mockNetwork.mockAudioData = Data("opus-bytes".utf8)
    let viewModel = QuizViewModel(
        networkService: mockNetwork,
        audioService: mockAudio,
        persistenceStore: MockPersistenceStore()
    )
    viewModel.currentQuestion = Fixtures.makeQuestion()
    viewModel.quizState = .askingQuestion
    return (viewModel, mockAudio)
}

// MARK: - Suite

@Suite("QuizViewModel TTS spy (RS-11)")
@MainActor
struct QuizViewModelTTSSpyTests {

    @Test("asking a question attempts TTS exactly once with the downloaded audio")
    func askingQuestionAttemptsTTS() async {
        let (viewModel, mockAudio) = makeAskingViewModel()

        await viewModel.audioDeviceState.playQuestionAudio(from: "https://example.com/q.mp3")

        #expect(mockAudio.playOpusCallCount == 1)
        #expect(mockAudio.lastPlayedData == Data("opus-bytes".utf8))

        // Stop the answer-timer scheduled in the post-TTS branch so it can't fire
        // mid-suite (silenceDetectionService is nil → legacy startAnswerTimer path).
        viewModel.quizTimersController.cancelAnswerTimer()
    }

    @Test("a failed TTS playback is swallowed and re-attempted on the next question")
    func failedTTSIsSwallowedAndRetried() async {
        let (viewModel, mockAudio) = makeAskingViewModel(failPlayback: true)

        // First question: playback throws internally — must NOT propagate, and the
        // quiz must stay in askingQuestion (not stranded), with TTS attempted once.
        await viewModel.audioDeviceState.playQuestionAudio(from: "https://example.com/q1.mp3")
        #expect(mockAudio.playOpusCallCount == 1)
        #expect(viewModel.quizState == .askingQuestion)
        viewModel.quizTimersController.cancelAnswerTimer()

        // Next question: TTS is attempted again (it is not disabled by a prior fail).
        viewModel.quizState = .askingQuestion
        await viewModel.audioDeviceState.playQuestionAudio(from: "https://example.com/q2.mp3")
        #expect(mockAudio.playOpusCallCount == 2)
        viewModel.quizTimersController.cancelAnswerTimer()
    }

    /// WHY (founder report "the question sometimes isn't read aloud", 2026-07-26):
    /// `proceedToNextQuestion()` opens with `taskBag.cancel(.autoAdvance)`. When the
    /// advance is driven BY the auto-advance countdown — the hands-free path, i.e.
    /// most of a drive — that cancels the very task it is running in, and the next
    /// question's TTS download dies with URLError.cancelled while the quiz sails on
    /// silently. The countdown must hand the advance to a fresh task. Playing the
    /// next question's audio is the observable proof it did.
    @Test("auto-advance reads the next question aloud (not cancelled by its own task)")
    func autoAdvanceStillReadsNextQuestion() async {
        let (viewModel, mockAudio) = makeAskingViewModel()
        viewModel.currentSession = Fixtures.makeQuizSession()
        viewModel.nextQuestion = Fixtures.makeQuestion(id: "q_002", text: "Next?", source: "Next")
        viewModel.nextQuestionAudioUrl = "https://example.com/q2.mp3"
        viewModel.quizState = .showingResult(
            question: Fixtures.makeQuestion(),
            evaluation: Evaluation(
                userAnswer: "Paris",
                result: .correct,
                points: 1.0,
                correctAnswer: "Paris",
                questionId: "q_001",
                explanation: nil
            )
        )

        await viewModel.quizTimersController.startAutoAdvanceCountdown(duration: 0, audioDuration: 0)

        // The advance runs on a task the countdown handed off to; give it turns to land.
        for _ in 0 ..< 200 where mockAudio.playOpusCallCount == 0 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(mockAudio.playOpusCallCount == 1)
        #expect(viewModel.quizState == .askingQuestion)
        viewModel.quizTimersController.cancelAnswerTimer()
        viewModel.quizTimersController.cancelThinkingTime()
    }
}
