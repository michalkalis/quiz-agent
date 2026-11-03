//
//  QuickGameTests.swift
//  HangsTests
//
//  #224.8 — "Quick game". The founder wants a faster mode for people who skip
//  a lot: after "Next" the next question comes at once, with only a brief note
//  of the right answer. The skip request itself must still go out, or the free
//  quota, stats and analytics would drift from what the player did; answered
//  questions and the default (off) flow must stay exactly as they were.
//

import Clocks
import Combine
import Foundation
@testable import Hangs
import Testing

@MainActor
private func response(_ result: Evaluation.EvaluationResult, next: Question? = Fixtures.makeQuestion(id: "q_next", text: "Next question?"), phase: String = "asking") -> QuizResponse {
    QuizResponse(
        success: true,
        message: "Input processed",
        session: Fixtures.makeQuizSession(phase: phase),
        currentQuestion: next,
        evaluation: Evaluation(
            userAnswer: result == .skipped ? "" : "Test",
            result: result,
            points: result == .correct ? 1.0 : 0.0,
            correctAnswer: "1989",
            questionId: "q_001",
            explanation: "Because.",
            headlineAnswer: nil
        ),
        feedbackReceived: [],
        audio: nil
    )
}

@MainActor
private struct Rig {
    let vm: QuizViewModel
    let network: MockNetworkService
    let analytics = MockAnalyticsClient()
    let clock = TestClock<Duration>()
    var states: StateLog

    /// Every state the quiz passes through, in order.
    @MainActor final class StateLog {
        var seen: [QuizState] = []
        var bag = Set<AnyCancellable>()
    }

    init(quick: Bool, result: Evaluation.EvaluationResult = .skipped) {
        network = Fixtures.makeFullMockNetwork()
        vm = QuizViewModel(
            networkService: network,
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService(),
            clock: AnyClock(clock),
            analytics: analytics
        )
        network.mockResponse = response(result)
        vm.settings.quickGame = quick
        vm.currentSession = Fixtures.makeQuizSession()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        vm.quizState = .askingQuestion
        let log = StateLog()
        vm.$quizState.sink { log.seen.append($0) }.store(in: &log.bag)
        states = log
    }

    /// The advance sits behind a real audio settle (#180 track A keeps it on wall time).
    func waitUntil(_ predicate: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline, !predicate() {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

@Suite("Quick game (#224.8)")
@MainActor
struct QuickGameTests {
    @Test("a skip goes straight to the next question and never enters a result state")
    func quickSkipHasNoResultScreen() async {
        let rig = Rig(quick: true)
        await rig.vm.skipQuestion()
        await rig.waitUntil { rig.vm.quizState == .askingQuestion && rig.vm.currentQuestion?.id == "q_next" }

        #expect(rig.vm.currentQuestion?.id == "q_next")
        #expect(!rig.states.seen.contains { $0.isShowingResult }, "the player would see the explanation the mode exists to skip")
    }

    @Test("the skip request still reaches the server, for the question that was skipped")
    func quickSkipStillCallsTheBackend() async {
        let rig = Rig(quick: true)
        await rig.vm.skipQuestion()
        #expect(rig.network.submitTextInputCallCount == 1, "no request would mean no quota, stats or recap row")
        #expect(rig.network.capturedTextInputInput == "skip")
        #expect(rig.network.capturedTextInputQuestionId == "q_001")
    }

    @Test("the next question shows the right answer of the skipped one, then the note leaves by itself")
    func noteShowsTheAnswerAndExpires() async {
        let rig = Rig(quick: true)
        await rig.vm.skipQuestion()
        await rig.waitUntil { rig.vm.quizState == .askingQuestion }
        #expect(rig.vm.quickSkipNote == "1989")

        await rig.clock.advance(by: QuizViewModel.quickSkipNoteDuration - .milliseconds(1))
        #expect(rig.vm.quickSkipNote == "1989", "gone early: the player has no time to read it")
        await rig.clock.advance(by: .milliseconds(1))
        await Task.yield()
        #expect(rig.vm.quickSkipNote == nil, "a note that stays would cover the next question")
    }

    @Test("with the mode off a skip still lands on the result screen, as before")
    func defaultSkipKeepsTheResultScreen() async {
        let rig = Rig(quick: false)
        await rig.vm.skipQuestion()
        #expect(rig.vm.quizState.isShowingResult)
        #expect(rig.vm.quickSkipNote == nil)
    }

    @Test("an answered question still shows its result in the quick game")
    func answersStillShowResults() async {
        let rig = Rig(quick: true, result: .incorrect)
        await rig.vm.submitSkip() // any submit path lands in handleQuizResponse
        #expect(rig.vm.quizState.isShowingResult, "only skips are quick")
        #expect(rig.vm.quickSkipNote == nil)
    }

    @Test("skipping the last question ends the set instead of showing a note")
    func lastSkipFinishes() async {
        let rig = Rig(quick: true)
        rig.network.mockResponse = response(.skipped, next: nil, phase: "finished")
        await rig.vm.skipQuestion()
        await rig.waitUntil { rig.vm.quizState == .finished }
        #expect(rig.vm.quizState == .finished)
    }

    @Test("every skip reports the mode, and flipping the switch is reported once")
    func analyticsCarryTheMode() async {
        let rig = Rig(quick: false)
        rig.vm.setQuickGame(true)
        rig.vm.setQuickGame(true)
        await rig.vm.skipQuestion()
        #expect(rig.analytics.events == [.quickGameChanged(enabled: true), .questionSkipped(quick: true)])
    }
}
