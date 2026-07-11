//
//  QuizViewModelReplayContractTests.swift
//  HangsTests
//
//  RS-16 / issue #59.7 — "Result read-aloud is wrong + auto-advance countdown".
//
//  Bug A: ResultView.readAloudButton called `playQuestionAudio` — the question-screen
//  flow function, which tears down silence detection and re-arms the think/answer
//  timers — instead of the timer-safe `replayQuestionAudio()`. On the result screen
//  that is wrong: it can silently drop playback and disturb the running auto-advance
//  countdown. These tests pin the contract difference the green-but-broken suite
//  never checked: `replayQuestionAudio()` plays audio AND leaves the countdown
//  untouched.
//
//  The mock audio stack replaces AVFoundation, so the TTS-spy counter
//  (playOpusCallCount, added for RS-11) is the only way to prove "audio was actually
//  attempted" on the simulator.
//

import Foundation
import Testing
@testable import Hangs

@Suite("QuizViewModel replay vs play contract (RS-16)")
@MainActor
struct QuizViewModelReplayContractTests {

    private func makeResultScreenViewModel() -> (QuizViewModel, MockAudioService) {
        let mockAudio = MockAudioService()
        let mockNetwork = Fixtures.makeFullMockNetwork()
        mockNetwork.mockAudioData = Data("opus-bytes".utf8)
        let viewModel = QuizViewModel(
            networkService: mockNetwork,
            audioService: mockAudio,
            persistenceStore: MockPersistenceStore()
        )
        return (viewModel, mockAudio)
    }

    @Test("replayQuestionAudio replays once and leaves the running countdown untouched")
    func replayDoesNotDisturbCountdown() async {
        let (viewModel, mockAudio) = makeResultScreenViewModel()

        // Simulate the result screen: a known question URL + a countdown already running.
        viewModel.currentQuestionAudioUrl = "https://example.com/q.mp3"
        viewModel.autoAdvanceCountdown = 6

        await viewModel.replayQuestionAudio()

        #expect(mockAudio.playOpusCallCount == 1) // it actually replays the question audio
        #expect(viewModel.autoAdvanceCountdown == 6) // ...without re-arming or cancelling the countdown
    }

    @Test("replayQuestionAudio is a harmless no-op when muted")
    func replayNoOpWhenMuted() async {
        let (viewModel, mockAudio) = makeResultScreenViewModel()
        viewModel.settings.isMuted = true
        viewModel.currentQuestionAudioUrl = "https://example.com/q.mp3"
        viewModel.autoAdvanceCountdown = 6

        await viewModel.replayQuestionAudio()

        #expect(mockAudio.playOpusCallCount == 0)
        #expect(viewModel.autoAdvanceCountdown == 6)
    }

    @Test("replayQuestionAudio is a harmless no-op when no question URL is known")
    func replayNoOpWhenNoURL() async {
        let (viewModel, mockAudio) = makeResultScreenViewModel()
        viewModel.currentQuestionAudioUrl = nil
        viewModel.autoAdvanceCountdown = 6

        await viewModel.replayQuestionAudio()

        #expect(mockAudio.playOpusCallCount == 0)
        #expect(viewModel.autoAdvanceCountdown == 6)
    }

    /// Tap-anywhere-on-question (founder, 2026-07-11): a second tap while the
    /// question TTS is still playing must STOP the in-flight playback and start
    /// it again from the top — not layer a second playback, and (the standing
    /// Decision 2 contract) still never re-arm the think/answer timers. The
    /// interrupted run is cancelled, so its tail must neither restore state over
    /// the newer run nor leak `isPlayingQuestionTTS == true` past the restart.
    @Test("tap during playback stops the in-flight TTS and restarts it, timers untouched")
    func replayRestartsDuringPlayback() async {
        let (viewModel, mockAudio) = makeResultScreenViewModel()
        viewModel.currentQuestionAudioUrl = "https://example.com/q.mp3"
        viewModel.autoAdvanceCountdown = 6

        // First tap: kick off a replay and wait until it is genuinely mid-playback
        // (the mock's playOpusAudio sleeps 0.1s while isPlayingQuestionTTS is true).
        let firstTap = Task { await viewModel.replayQuestionAudio() }
        var spins = 0
        while mockAudio.playOpusCallCount == 0, spins < 10_000 {
            await Task.yield()
            spins += 1
        }
        #expect(mockAudio.playOpusCallCount == 1)
        #expect(viewModel.isPlayingQuestionTTS)

        // Second tap mid-playback: restart.
        await viewModel.replayQuestionAudio()
        await firstTap.value

        #expect(mockAudio.stopPlaybackCallCount >= 1) // the in-flight TTS was stopped first
        #expect(mockAudio.playOpusCallCount == 2) // ...and playback restarted from the top
        #expect(viewModel.isPlayingQuestionTTS == false) // no leaked flag from the cancelled run
        #expect(viewModel.autoAdvanceCountdown == 6) // timers never re-armed or cancelled
        #expect(viewModel.thinkingTimeCountdown == 0)
        #expect(viewModel.answerTimerCountdown == 0)
    }
}
