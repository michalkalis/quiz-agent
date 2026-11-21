//
//  ResultHearItHoldTests.swift
//  HangsTests
//
//  RS-16 flaked in CI after #240.9 shortened the result's countdown to 3 s
//  after the spoken verdict. Behind it: "hear it" never held the result
//  itself, only the screen-wide tap gesture did, so any activation that was
//  no touch (VoiceOver) let the result move on in the middle of the
//  explanation. These pin the hold in the view model, on the test's clock.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@Suite("The result waits while its explanation is read")
@MainActor
struct ResultHearItHoldTests {
    private struct Rig {
        let vm: QuizViewModel
        let audio: MockAudioService
    }

    private func makeRig(clock: TestClock<Duration>) -> Rig {
        let audio = MockAudioService()
        audio.playbackDurationNs = 0
        let vm = QuizViewModel(
            networkService: Fixtures.makeFullMockNetwork(),
            audioService: audio,
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService(),
            clock: AnyClock(clock)
        )
        vm.settleClock = AnyClock(clock)
        vm.currentSession = Fixtures.makeQuizSession()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        return Rig(vm: vm, audio: audio)
    }

    private func showResult(_ rig: Rig, audio: AudioInfo?) async {
        rig.vm.quizState = .processing
        await rig.vm.handleQuizResponse(QuizResponse(
            success: true,
            message: "",
            session: Fixtures.makeQuizSession(),
            currentQuestion: Fixtures.makeQuestion(id: "q_002"),
            evaluation: Evaluation(userAnswer: "4", result: .correct, points: 1, correctAnswer: "4", questionId: "q_001", explanation: nil),
            feedbackReceived: [],
            audio: audio
        ))
        #expect(rig.vm.quizState.isShowingResult)
    }

    /// Step by step, yielding between steps, so a countdown that should not
    /// run gets every chance to (one big jump can skip its later ticks).
    private func advance(_ clock: TestClock<Duration>, by total: Duration) async {
        var elapsed: Duration = .zero
        while elapsed < total {
            for _ in 0 ..< 20 {
                await Task.yield()
            }
            await clock.advance(by: .milliseconds(100))
            elapsed += .milliseconds(100)
        }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
    }

    private let spokenVerdict = AudioInfo(feedbackUrl: nil, feedbackAudioBase64: "AAAA", questionUrl: nil, format: "opus")

    /// The CI shape: "hear it" while the verdict is still spoken. Once the
    /// verdict ends, only 3 s used to stand between the player and the next
    /// question, explanation or not.
    @Test("'hear it' during the spoken verdict keeps the result after the verdict ends")
    func hearItDuringTheVerdictHoldsTheResult() async {
        let clock = TestClock()
        let rig = makeRig(clock: clock)
        rig.audio.holdsPlaybackUntilStopped = true
        await showResult(rig, audio: spokenVerdict)
        await pumpUntil({ rig.vm.isAwaitingSpokenVerdict }, "precondition: the verdict is being spoken")

        rig.vm.readExplanationAloud("Four is two plus two.")
        rig.audio.holdsPlaybackUntilStopped = false
        await rig.audio.stopPlayback() // the verdict ends
        await advance(clock, by: .seconds(Config.pauseAfterSpokenVerdict + 10))

        #expect(rig.vm.quizState.isShowingResult, "the result moved on while its explanation was read")
        #expect(rig.vm.currentQuestion?.id == "q_001")
        #expect(rig.vm.isPaused, "the toolbar shows the hold, so the player knows how to go on")
    }

    @Test("'hear it' while the countdown runs stops it")
    func hearItDuringTheCountdownHoldsTheResult() async {
        let clock = TestClock()
        let rig = makeRig(clock: clock)
        await showResult(rig, audio: nil)
        await pumpUntil({ rig.vm.autoAdvanceCountdown > 0 }, "precondition: the countdown runs")

        rig.vm.readExplanationAloud("Four is two plus two.")
        await advance(clock, by: .seconds(rig.vm.settings.autoAdvanceDelay + 5))

        #expect(rig.vm.quizState.isShowingResult, "the countdown ran out under the explanation")
        #expect(rig.vm.isPaused)
    }

    /// The player's own pause and resume stay theirs: a read on a held result
    /// changes nothing, and Next still goes on at once.
    @Test("'hear it' on a paused result leaves the pause alone, Next still moves on")
    func hearItOnAPausedResult() async {
        let clock = TestClock()
        let rig = makeRig(clock: clock)
        await showResult(rig, audio: nil)
        rig.vm.pauseQuiz()

        rig.vm.readExplanationAloud("Four is two plus two.")
        #expect(rig.vm.isPaused)

        rig.vm.continueToNext()
        _ = await advanceUntil(clock, step: .milliseconds(100), limit: .seconds(2), {
            rig.vm.currentQuestion?.id == "q_002"
        }, "Next did not move on from a held result")
    }
}
