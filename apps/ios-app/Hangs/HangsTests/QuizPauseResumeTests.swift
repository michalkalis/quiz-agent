//
//  QuizPauseResumeTests.swift
//  HangsTests
//
//  #200 — TestFlight of the 1.1 redesign (founder, 2026-10-12): the toolbar
//  pause has to be a real pause, i.e. play picks up exactly where it stopped.
//   - Paused while the question was being read, then play: the read never
//     came back and the think window started over a question the driver only
//     half heard.
//   - Paused while "Premýšľaj" was counting down, then play: the countdown
//     restarted at full instead of continuing.
//  Time is a `TestClock`; audio and network are the mocks (the mock clip is
//  held by a pause exactly like the real AVPlayer clip — see MockAudioService).
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@MainActor
private func drain() async {
    for _ in 0 ..< 30 {
        await Task.yield()
    }
}

@Suite("Pause keeps the question read and the thinking time (#200)")
@MainActor
struct QuizPauseResumeTests {
    private static let questionAudio = "https://example.invalid/q.opus"

    private func makeVM(clock: TestClock<Duration>) -> (QuizViewModel, MockAudioService) {
        let audio = MockAudioService()
        audio.playbackDurationNs = 0
        let vm = QuizViewModel(
            networkService: Fixtures.makeFullMockNetwork(),
            audioService: audio,
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService(),
            sttService: nil,
            clock: AnyClock(clock)
        )
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Fixtures.makeQuestion()
        vm.quizState = .askingQuestion
        vm.settings.thinkingTime = 10
        return (vm, audio)
    }

    /// Starts the question read and pauses it the moment the clip is playing.
    private func readAndPause(_ vm: QuizViewModel, _ audio: MockAudioService) async -> Task<Void, Never> {
        audio.onPlaybackStarted = { [weak vm] in vm?.togglePause() }
        let readOut = Task { await vm.audioDeviceState.playQuestionAudio(from: Self.questionAudio) }
        await pumpUntil({ vm.isPaused }, "the read-out never started")
        audio.onPlaybackStarted = nil
        await drain()
        return readOut
    }

    /// WHY (finding A): a driver who pauses mid-question must hear the REST of
    /// it after play — not nothing, and not a think countdown over a question
    /// they never finished hearing. The pause holds the clip; play continues
    /// the same clip, and only its end arms the think window.
    @Test("a pause during the question read holds it; play continues the same clip, then the think window")
    func pauseDuringReadOutContinuesTheClip() async {
        let clock = TestClock()
        let (vm, audio) = makeVM(clock: clock)
        let readOut = await readAndPause(vm, audio)

        #expect(audio.isPlaybackPaused, "the pause must hold the clip, not end it")
        #expect(vm.isPlayingQuestionTTS, "the held read still owns the question")
        await clock.advance(by: .seconds(60))
        #expect(vm.thinkingTimeCountdown == 0, "a paused read must not arm the think window")
        #expect(vm.quizState == .askingQuestion)

        vm.togglePause()
        await readOut.value

        #expect(audio.playOpusCallCount == 1, "play continues the SAME clip — the question is not restarted")
        await pumpUntil({ vm.thinkingTimeCountdown == 10 }, "the finished read never armed the think window")
    }

    /// WHY (finding A, fallback): the held clip can be lost while paused (a
    /// call, a route change tearing the player down). Play must then read the
    /// question again from the start — never jump silently to the countdown,
    /// which is exactly what the driver reported.
    @Test("a held read that is lost while paused is read again from the start on play")
    func lostReadOutIsReadAgain() async {
        let clock = TestClock()
        let (vm, audio) = makeVM(clock: clock)
        let readOut = await readAndPause(vm, audio)

        await audio.stopPlayback() // the player is gone, as after an interruption
        await readOut.value
        await drain()
        #expect(vm.thinkingTimeCountdown == 0, "still paused — nothing may count down")

        var countdownWhenReadAgain: Int?
        audio.onPlaybackStarted = { [weak vm] in countdownWhenReadAgain = vm?.thinkingTimeCountdown }
        vm.togglePause()

        await pumpUntil({ audio.playOpusCallCount == 2 }, "play did not read the question again")
        #expect(countdownWhenReadAgain == 0, "the think window must not run over the repeated question")
        await pumpUntil({ vm.thinkingTimeCountdown == 10 }, "the repeated read never armed the think window")
    }

    /// WHY: answering or skipping ends a pause without play, so a held read can
    /// outlive the pause that held it. A later pause that holds nothing must not
    /// inherit it — play would then read again a question nobody cut short.
    @Test("a hold an earlier pause left behind never makes a later play re-read")
    func staleHoldIsNotInherited() async {
        let clock = TestClock()
        let (vm, audio) = makeVM(clock: clock)
        let readOut = await readAndPause(vm, audio)
        vm.isPaused = false // what an answer tap or a skip does to the pause
        await audio.stopPlayback()
        await readOut.value
        vm.quizTimersController.cancelThinkingTime()

        vm.togglePause() // nothing is being read now
        vm.togglePause()

        await pumpUntil({ vm.thinkingTimeCountdown == 10 }, "play did not arm the think window")
        #expect(audio.playOpusCallCount == 1, "play read the question again although nothing was cut")
        vm.quizTimersController.cancelThinkingTime()
    }

    /// WHY (finding B): the think window is the driver's own time. A pause
    /// must freeze it — play continues with what was left, exactly to the
    /// second the shipped countdown would have used, and only then does the
    /// mic open on its own.
    @Test("play continues a paused think window from its remainder, then auto-records")
    func pausedThinkWindowContinuesFromRemainder() async {
        let clock = TestClock()
        let (vm, _) = makeVM(clock: clock)
        vm.startRecordingOrTimer()
        await pumpUntil({ vm.thinkingTimeCountdown == 10 }, "the think window never started")
        await clock.advance(by: .seconds(4))
        #expect(vm.thinkingTimeCountdown == 6, "precondition: 4 s of 10 spent")

        vm.togglePause()
        #expect(vm.thinkingTimeCountdown == 0, "a paused window must not keep counting")
        await clock.advance(by: .seconds(60))
        #expect(vm.quizState == .askingQuestion, "the mic opened during the pause")

        vm.togglePause()
        await pumpUntil({ vm.thinkingTimeCountdown == 6 }, "play must continue from the remaining 6 s, not restart at 10")

        await clock.advance(by: .milliseconds(5900))
        #expect(vm.quizState == .askingQuestion, "the window ended before its remainder ran out")
        await clock.advance(by: .milliseconds(200))
        await pumpUntil({ vm.quizState == .recording }, "the remainder ran out but the mic never opened")
        vm.quizTimersController.cancelAutoStopRecordingTimer()
    }
}
