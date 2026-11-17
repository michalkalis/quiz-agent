//
//  QuizStartConditionTests.swift
//  HangsTests
//
//  #235.2 (flow × condition, quiz start row). A start retries connection
//  failures for up to 24 s (`TransientRetry.retryWindow`) so a server that is
//  waking or restarting costs a pause, not the quiz. On a network that never
//  recovers that window must END: the player waits on Home's spinner (with
//  Cancel, `HomeViewInspectorTests`) and then gets the error screen with Try
//  again, never a spinner forever. Slow starts, Cancel and tab switches are
//  covered in QuizViewModelTests, SlowQuizStartTabTests and the navigation
//  sequence suite; these cover timeout, offline, dropped and malformed.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@Suite("Quiz start on a bad network (#235.2)")
@MainActor
struct QuizStartConditionTests {
    private struct Rig {
        let vm: QuizViewModel
        let network: MockNetworkService
        let clock: TestClock<Duration>
    }

    private final class Counter {
        var value = 0
    }

    private func makeRig() -> Rig {
        let clock = TestClock()
        let network = Fixtures.makeFullMockNetwork()
        network.networkClock = AnyClock(clock)
        let audio = MockAudioService()
        audio.playbackDurationNs = 0
        let vm = QuizViewModel(
            networkService: network,
            audioService: audio,
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService(),
            clock: AnyClock(clock)
        )
        return Rig(vm: vm, network: network, clock: clock)
    }

    // WHY: a request that never answers costs the 30 s request timeout, which
    // is already past the retry window, so it is NOT tried again (that used to
    // stack 3 × 30 s). The player sees the spinner until then, never an error
    // sooner, and the error screen right after.
    @Test("a start the server never answers shows the error with Try again after one request timeout")
    func neverAnsweredStartEndsOnError() async {
        let rig = makeRig()
        rig.network.setNetworkCondition(.timeout, for: [.createSession])
        let start = rig.vm.beginQuizStart()
        await pumpUntil { rig.network.createSessionCallCount == 1 }

        await rig.clock.advance(by: NetworkCondition.requestTimeout - .milliseconds(1))
        #expect(rig.vm.quizState == .startingQuiz, "the spinner gave up before the request timeout")
        await rig.clock.advance(by: .milliseconds(1))
        await start.value

        #expect(rig.vm.quizState.isError)
        #expect(rig.vm.activeErrorModel?.retryAction == .retryOperation)
        #expect(rig.network.createSessionCallCount == 1, "a timed-out start was retried past its window")
    }

    // WHY: offline in a tunnel the start keeps retrying, but only within its
    // window; after that the player must get the error screen with Try again.
    @Test("a start with no connection retries within its window, then shows the error with Try again")
    func offlineStartEndsOnErrorAfterWindow() async {
        let rig = makeRig()
        rig.network.setNetworkCondition(.offline, for: [.createSession])
        let start = rig.vm.beginQuizStart()

        let waited = await advanceUntil(rig.clock, limit: .seconds(60)) { rig.vm.quizState.isError }
        await start.value

        #expect(waited <= TransientRetry.retryWindow + .seconds(1), "the player waited past the retry window")
        #expect(rig.network.createSessionCallCount > 1, "a lost connection was not retried")
        #expect(rig.vm.activeErrorModel?.retryAction == .retryOperation)
    }

    // WHY: a connection that drops after the session exists is retried on
    // THAT session: a second session would be an orphan the server never
    // closes, and the player would get no question.
    @Test("a start dropped after the session exists is retried on the same session and the quiz begins")
    func droppedStartRetriesSameSession() async {
        let rig = makeRig()
        let startQuizCalls = Counter()
        rig.network.onStartQuiz = { startQuizCalls.value += 1 }
        rig.network.setNetworkCondition(.dropped(after: .seconds(2)), for: [.startQuiz])
        let start = rig.vm.beginQuizStart()
        await pumpUntil { startQuizCalls.value == 1 }
        rig.network.setNetworkCondition(nil, for: [.startQuiz])

        await advanceUntil(rig.clock, limit: .seconds(10)) { rig.vm.quizState == .askingQuestion }
        await start.value

        #expect(startQuizCalls.value == 2)
        #expect(rig.network.createSessionCallCount == 1, "the retry opened a second session")
    }

    // WHY: a first question the app cannot read is permanent; the player gets
    // the error screen at once instead of 24 s of pointless retries.
    @Test("a first question that cannot be read shows the error at once, without retrying")
    func malformedStartFailsAtOnce() async {
        let rig = makeRig()
        let startQuizCalls = Counter()
        rig.network.onStartQuiz = { startQuizCalls.value += 1 }
        rig.network.setNetworkCondition(.malformed, for: [.startQuiz])

        await rig.vm.beginQuizStart().value

        #expect(rig.vm.quizState.isError)
        #expect(rig.vm.activeErrorModel?.retryAction == .retryOperation)
        #expect(startQuizCalls.value == 1)
    }
}
