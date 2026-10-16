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
//  - The bar then showed "Reading the question" for the whole pause, because
//    the paused countdown reads 0: a paused think window has to keep showing
//    the think state with the seconds it was frozen at.
//  Time is a `TestClock`; audio and network are the mocks (the mock clip is
//  held by a pause exactly like the real AVPlayer clip — see MockAudioService).
//


import Clocks
import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

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

    // MARK: - What the bar shows while the think window is paused

    /// 4 s of a 10 s window spent, then the toolbar pause: the window is held
    /// with 6 s left.
    private func pauseMidThinkWindow(_ vm: QuizViewModel, _ clock: TestClock<Duration>) async {
        vm.startRecordingOrTimer()
        await pumpUntil({ vm.thinkingTimeCountdown == 10 }, "the think window never started")
        await clock.advance(by: .seconds(4))
        vm.togglePause()
    }

    /// WHY: the paused countdown reads 0, and 0 is how the bar tells "the
    /// question is still being read" from "the driver is thinking". A paused
    /// think window therefore fell back to "Reading the question" — the bar
    /// claimed the app was talking while it was silent and waiting. It has to
    /// keep the think state, frozen at the seconds the window was held with.
    @Test("a paused think window keeps showing the think state with its frozen seconds")
    func pausedThinkWindowKeepsItsBarState() async throws {
        let clock = TestClock()
        let (vm, _) = makeVM(clock: clock)
        let question = try #require(vm.currentQuestion)
        await pauseMidThinkWindow(vm, clock)

        #expect(vm.listenPhase(for: question) == .thinking(remaining: 6, total: 10),
                "the bar must not fall back to reading the question")
        await clock.advance(by: .seconds(60))
        #expect(vm.listenPhase(for: question) == .thinking(remaining: 6, total: 10),
                "frozen means the number does not move while paused")

        vm.togglePause()
        await pumpUntil({ vm.thinkingTimeCountdown == 6 }, "play must continue from the remaining 6 s")
        #expect(vm.listenPhase(for: question) == .thinking(remaining: 6, total: 10))
        vm.quizTimersController.cancelThinkingTime()
    }

    /// WHY: the other half of the same rule. A pause during the read-out holds
    /// no seconds, and there the bar rightly still says the question is being
    /// read — the fix must not turn that into an empty think window.
    @Test("a pause during the question read keeps the bar on reading the question")
    func pausedReadOutStillReads() async throws {
        let clock = TestClock()
        let (vm, audio) = makeVM(clock: clock)
        let question = try #require(vm.currentQuestion)
        let readOut = await readAndPause(vm, audio)

        #expect(vm.listenPhase(for: question) == .readingQuestion)
        vm.togglePause()
        await readOut.value
        vm.quizTimersController.cancelThinkingTime()
    }

    /// WHY: answering or skipping ends a pause without play (see
    /// `staleHoldIsNotInherited`), so the seconds a pause held can outlive it.
    /// They must never show on a bar that is not paused — it would count a
    /// window that is not running.
    @Test("seconds a finished pause left behind never show on the bar")
    func staleHeldSecondsDoNotShow() async throws {
        let clock = TestClock()
        let (vm, _) = makeVM(clock: clock)
        let question = try #require(vm.currentQuestion)
        await pauseMidThinkWindow(vm, clock)

        vm.isPaused = false // what an answer tap or a skip does to the pause

        // #208: and nothing reads either, so it is the bare command bar.
        #expect(vm.listenPhase(for: question) == .thinking(remaining: 0, total: 0), "no window is running, so none may be shown")
        #expect(vm.listenPhase(for: question)?.countdown == nil)
    }

    /// WHY: what the founder tests on device is what the driver SEES, on both
    /// question types, so the rendered bar is asserted too: the think caption
    /// and the frozen number, and not the reading caption.
    @Test("the paused screen renders the think bar with the frozen number, on both question types",
          arguments: [Question.preview, Question.previewMCQ])
    func pausedThinkWindowRenders(question: Question) async throws {
        let clock = TestClock()
        let (vm, _) = makeVM(clock: clock)
        vm.currentQuestion = question
        await pauseMidThinkWindow(vm, clock)
        #expect(vm.isPaused, "precondition: the toolbar shows the paused play control")

        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            // The full bar shows the state word and a trailing "6 s"; the slim
            // bar a short screen gets folds the seconds into its caption.
            let fullBar = (try? tree.find(viewWithAccessibilityIdentifier: "listen-bar.seconds").text().string())
                == "6 s"
            let slimBar = (try? tree.find(text: "THINK. LISTENING IN 6 S")) != nil
            #expect(fullBar || slimBar, "the bar lost the think state and its frozen 6 s")
            #expect(throws: (any Error).self, "the bar claims the app is reading while it is paused and silent") {
                try tree.find(text: "Reading the question")
            }
        }
    }
}
