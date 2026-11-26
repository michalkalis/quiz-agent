//
//  ResultExplanationAutoReadTests.swift
//  HangsTests
//
//  #249 (founder, TF 1.3 b93, 2026-11-26): "chcel by som počuť vysvetlenia
//  na výsledku". The result reads its explanation after the verdict by
//  default; Quick quiz and read-aloud off skip it. Under a slow or failing
//  server the result still moves on: never an endless wait.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@Suite("#249 the result reads its explanation")
@MainActor
struct ResultExplanationAutoReadTests {
    private struct Rig {
        let vm: QuizViewModel
        let network: MockNetworkService
    }

    private let why = "Two and two make four."

    private func makeRig(clock: TestClock<Duration>) -> Rig {
        let audio = MockAudioService()
        audio.playbackDurationNs = 0
        let network = Fixtures.makeFullMockNetwork()
        network.networkClock = AnyClock(clock)
        let vm = QuizViewModel(
            networkService: network,
            audioService: audio,
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService(),
            clock: AnyClock(clock)
        )
        vm.settleClock = AnyClock(clock)
        vm.currentSession = Fixtures.makeQuizSession()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        return Rig(vm: vm, network: network)
    }

    private func showResult(_ rig: Rig) async {
        rig.vm.quizState = .processing
        await rig.vm.handleQuizResponse(QuizResponse(
            success: true,
            message: "",
            session: Fixtures.makeQuizSession(),
            currentQuestion: Fixtures.makeQuestion(id: "q_002"),
            evaluation: Evaluation(userAnswer: "4", result: .correct, points: 1, correctAnswer: "4", questionId: "q_001", explanation: why),
            feedbackReceived: [],
            audio: nil
        ))
        #expect(rig.vm.quizState.isShowingResult)
    }

    private func movesOn(_ rig: Rig, _ clock: TestClock<Duration>, _ comment: Comment) async {
        _ = await advanceUntil(clock, step: .milliseconds(500), limit: .seconds(20), {
            rig.vm.currentQuestion?.id == "q_002"
        }, comment)
    }

    /// WHY: the founder wants to hear why an answer is right without tapping.
    /// The countdown must wait for the explanation (a slow server included),
    /// or the next question would cut it off.
    @Test("by default the explanation is read, and the countdown waits for it")
    func readsExplanationThenMovesOn() async {
        let clock = TestClock()
        let rig = makeRig(clock: clock)
        let hold = rig.network.hold(.synthesizeSpeech)
        await showResult(rig)

        await pumpUntil({ rig.network.synthesizedTexts == [why] }, "the explanation was never fetched")
        await pumpUntil({ rig.vm.isAwaitingSpokenVerdict }, "the bar is not held while the explanation is on its way")
        await clock.advance(by: .seconds(15))
        #expect(rig.vm.quizState.isShowingResult, "moved on before the explanation was read")
        #expect(rig.vm.autoAdvanceCountdown == 0)

        hold.release()
        await movesOn(rig, clock, "the result never moved on after the explanation")
        #expect(rig.vm.readAloudFailure == nil)
    }

    /// WHY: a server that cannot synthesize must not leave the player on the
    /// result for good; the note and "hear it" say it failed.
    @Test("an explanation that cannot be fetched shows the note and still moves on")
    func failedFetchStillMovesOn() async {
        let clock = TestClock()
        let rig = makeRig(clock: clock)
        rig.network.setNetworkCondition(.offline, for: [.synthesizeSpeech])
        await showResult(rig)

        await pumpUntil({ rig.vm.readAloudFailure == .explanation }, "a failed read was silent")
        await movesOn(rig, clock, "a failed read held the result")
    }

    /// WHY: Quick quiz is for pace (founder: "rýchly mód ich vypína"), and
    /// read-aloud off promises the app reads nothing.
    @Test("Quick quiz and read-aloud off read no explanation", arguments: ["quick", "muted"])
    func quickOrMutedReadsNothing(mode: String) async {
        let clock = TestClock()
        let rig = makeRig(clock: clock)
        if mode == "quick" { rig.vm.settings.quickGame = true } else { rig.vm.settings.isMuted = true }
        #expect(!rig.vm.readsExplanationOnResult)
        await showResult(rig)

        await movesOn(rig, clock, "the result did not move on")
        #expect(!rig.network.synthesizedTexts.contains(why), "the explanation was read in \(mode) mode")
    }
}
