//
//  AnsweringConditionTests.swift
//  HangsTests
//
//  #235.2 (flow × condition, answering row). Most cells of this row already
//  have tests (SubmitRetryTests, SubmissionStallTests, MCQSubmitInterruptTests,
//  QuizSequence). These fill the gaps: an answer whose reply cannot be read,
//  a connection that drops mid-answer, and a reply that lands after the
//  player left the quiz. The rules: the player always gets a result or a
//  clear error with Try again, an answer is never sent twice for a different
//  question (that would charge the quota twice), and a late reply never pulls
//  the player back into a quiz they left.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@Suite("Answering on a bad network (#235.2)")
@MainActor
struct AnsweringConditionTests {
    private struct Rig {
        let vm: QuizViewModel
        let network: MockNetworkService
        let clock: TestClock<Duration>
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
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        vm.quizState = .askingQuestion
        return Rig(vm: vm, network: network, clock: clock)
    }

    enum Answer: String, CaseIterable {
        case option, typed, skip
    }

    private func answer(_ kind: Answer, _ vm: QuizViewModel) async {
        switch kind {
        case .option: await vm.submitMCQAnswer(key: "a", value: "Paris")
        case .typed: await vm.resubmitAnswer("Paris")
        case .skip: await vm.skipQuestion()
        }
    }

    // WHY: a reply the app cannot read is permanent; retrying it could only
    // charge the answer again. The player must land on the error screen with
    // Try again, after exactly one request.
    @Test("an answer whose reply cannot be read shows the error with Try again, sent once", arguments: Answer.allCases)
    func malformedReplyShowsRetryOnce(kind: Answer) async {
        let rig = makeRig()
        rig.network.setNetworkCondition(.malformed, for: [.submitTextInput])

        await answer(kind, rig.vm)

        #expect(rig.vm.quizState.isError)
        #expect(rig.vm.activeErrorModel?.retryAction == .retryOperation)
        #expect(rig.network.submitTextInputCallCount == 1, "an unreadable reply was retried")
    }

    // WHY: the same for a voice answer, whose upload takes its own path.
    @Test("a voice answer whose reply cannot be read shows the error with Try again, sent once")
    func malformedVoiceReplyShowsRetryOnce() async {
        let rig = makeRig()
        rig.network.setNetworkCondition(.malformed, for: [.submitVoiceAnswer])
        await rig.vm.toggleRecording()
        #expect(rig.vm.quizState == .recording)
        rig.vm.mockSilence?.simulateAnswerAudio(Data(count: 32000))

        await rig.vm.toggleRecording()
        await pumpUntil({ rig.vm.quizState.isError }, "the unreadable voice reply left the player waiting")

        #expect(rig.vm.activeErrorModel?.retryAction == .retryOperation)
        #expect(rig.network.submitVoiceAnswerCallCount == 1)
    }

    // WHY: a connection that drops after the answer went out is retried; the
    // retry must carry the SAME question id, so the server replays its grading
    // instead of charging a second answer (#133 1a), and the player gets the
    // result without seeing an error.
    @Test("a connection dropped mid-answer is retried for the same question and the result arrives")
    func droppedAnswerRetriesSameQuestion() async {
        let rig = makeRig()
        rig.network.setNetworkCondition(.dropped(after: .seconds(2)), for: [.submitTextInput])
        let tap = Task { await rig.vm.submitMCQAnswer(key: "a", value: "Paris") }
        await pumpUntil { rig.network.submitTextInputCallCount == 1 }
        rig.network.setNetworkCondition(nil, for: [.submitTextInput])

        await advanceUntil(rig.clock, limit: .seconds(10)) { rig.network.submitTextInputCallCount == 2 }
        await tap.value

        #expect(rig.vm.quizState.isShowingResult)
        #expect(rig.network.capturedTextInputQuestionId == "q_001", "the retry answered another question")
    }

    // WHY: the player tapped an option, the reply was slow, and they ended the
    // quiz. When the reply lands they are on Home; it must not reopen the
    // result or add to a score nobody sees.
    @Test("a reply that lands after the player ended the quiz leaves them on Home")
    func lateReplyAfterEndStaysHome() async {
        let rig = makeRig()
        let hold = rig.network.hold(.submitTextInput)
        let tap = Task { await rig.vm.submitMCQAnswer(key: "a", value: "Paris") }
        await pumpUntil { hold.heldCount == 1 }
        #expect(rig.vm.quizState == .processing, "the player must see the answer is being checked")

        await rig.vm.endQuiz()
        #expect(rig.vm.quizState == .idle)
        hold.release()
        await tap.value

        #expect(rig.vm.quizState == .idle, "a late reply pulled the player back into the quiz")
        #expect(rig.vm.recapEntries.isEmpty)
        #expect(rig.vm.sessionCorrectCount == 0)
    }

    // WHY: worse than a late result is a late FAILURE: the player left, started
    // a new quiz, and the old answer's error must not throw the new start onto
    // the error screen.
    @Test("a failure that lands after the player left does not hijack the next quiz's start")
    func lateFailureAfterLeavingSparesNextStart() async {
        let rig = makeRig()
        rig.network.setNetworkCondition(.serverError(statusCode: 500), for: [.submitTextInput])
        let submitHold = rig.network.hold(.submitTextInput)
        let tap = Task { await rig.vm.submitMCQAnswer(key: "a", value: "Paris") }
        await pumpUntil { submitHold.heldCount == 1 }
        await rig.vm.endQuiz()

        let startHold = rig.network.hold(.startQuiz)
        let start = rig.vm.beginQuizStart()
        await pumpUntil { startHold.heldCount == 1 }
        submitHold.release()
        await tap.value
        #expect(rig.vm.quizState == .startingQuiz, "the old answer's failure took over the new start")

        startHold.release()
        await start.value
        #expect(rig.vm.quizState == .askingQuestion)
    }
}
