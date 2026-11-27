//
//  ResultExplanationGapTests.swift
//  HangsTests
//
//  #251 (founder, TF 1.3 b94, 2026-11-27): "pauza medzi odpoveďou a
//  vysvetlením na result obrazovke je zbytočne dlhá". Two things sat between
//  the spoken verdict and the explanation: the explanation's speech was only
//  requested when the result appeared, and the recognizer was started after
//  the verdict only to be torn down again for the explanation.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@Suite("#251 the explanation follows the verdict without a gap")
@MainActor
struct ResultExplanationGapTests {
    private struct Rig {
        let vm: QuizViewModel
        let network: MockNetworkService
        let silence: MockSilenceDetectionService
    }

    private let why = "Two and two make four."

    private func makeRig(clock: TestClock<Duration>) -> Rig {
        let audio = MockAudioService()
        audio.playbackDurationNs = 0
        let network = Fixtures.makeFullMockNetwork()
        network.networkClock = AnyClock(clock)
        let silence = MockSilenceDetectionService()
        let vm = QuizViewModel(
            networkService: network,
            audioService: audio,
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: silence,
            clock: AnyClock(clock)
        )
        vm.settleClock = AnyClock(clock)
        vm.currentSession = Fixtures.makeQuizSession()
        vm.currentQuestion = question(explanation: why)
        vm.quizState = .askingQuestion
        return Rig(vm: vm, network: network, silence: silence)
    }

    private func question(explanation: String?) -> Question {
        let q = Fixtures.makeQuestion(id: "q_001")
        return Question(
            id: q.id, question: q.question, type: q.type, possibleAnswers: nil,
            difficulty: q.difficulty, topic: q.topic, category: q.category,
            sourceUrl: q.sourceUrl, sourceExcerpt: q.sourceExcerpt, mediaUrl: nil,
            imageSubtype: nil, explanation: explanation, generatedBy: nil
        )
    }

    /// The answer is sent: the state machine's own entry into processing.
    private func sendAnswer(_ rig: Rig) {
        #expect(rig.vm.transition(to: .processing))
    }

    private func showResult(_ rig: Rig, verdict: AudioInfo? = nil) async {
        await rig.vm.handleQuizResponse(QuizResponse(
            success: true,
            message: "",
            session: Fixtures.makeQuizSession(),
            currentQuestion: Fixtures.makeQuestion(id: "q_002"),
            evaluation: Evaluation(userAnswer: "4", result: .correct, points: 1, correctAnswer: "4", questionId: "q_001", explanation: why),
            feedbackReceived: [],
            audio: verdict
        ))
        #expect(rig.vm.quizState.isShowingResult)
    }

    private func movesOn(_ rig: Rig, _ clock: TestClock<Duration>, _ comment: Comment) async {
        _ = await advanceUntil(clock, step: .milliseconds(500), limit: .seconds(20), {
            rig.vm.currentQuestion?.id == "q_002"
        }, comment)
    }

    /// WHY: the server answers the evaluation and the speech in parallel only
    /// if the speech is asked for when the answer goes out. Asked for at the
    /// result, its whole round trip is silence after "Správne."
    @Test("the explanation's speech is requested as the answer is sent, and only once")
    func requestedWithTheAnswer() async {
        let clock = TestClock()
        let rig = makeRig(clock: clock)
        sendAnswer(rig)
        await pumpUntil({ rig.network.synthesizedTexts == [why] }, "the explanation was not requested with the answer")

        await showResult(rig)
        await movesOn(rig, clock, "the result never moved on")
        #expect(rig.network.synthesizedTexts == [why], "the result fetched the explanation a second time")
        #expect(rig.vm.readAloudFailure == nil)
    }

    /// WHY: the recognizer's start-up (engine, analyzer, settle) is audible
    /// dead air. Between two lines the app speaks itself, nothing listens, so
    /// nothing may start it.
    @Test("the mic is not re-armed between the verdict and the explanation")
    func noListenerBetweenVerdictAndExplanation() async {
        let clock = TestClock()
        let rig = makeRig(clock: clock)
        let hold = rig.network.hold(.synthesizeSpeech)
        sendAnswer(rig)
        let verdict = AudioInfo(feedbackUrl: nil, feedbackAudioBase64: "ZmFrZQ==", questionUrl: nil, format: "opus")
        await showResult(rig, verdict: verdict)

        await pumpUntil(
            { !rig.vm.isPlayingFeedbackTTS && rig.vm.isAwaitingSpokenVerdict && rig.vm.explanationSpeechPrefetch == nil },
            "the verdict never finished"
        )
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(!rig.silence.isListening, "the verdict's end started the recognizer before the explanation")

        hold.release()
        await movesOn(rig, clock, "the result never moved on after the explanation")
    }

    /// WHY (#235): a speech request sent early can still be slow or fail. A
    /// failure must show the note and let the result move on, never hold it.
    @Test("an early request that fails shows the note and the result moves on")
    func earlyFailureStillMovesOn() async {
        let clock = TestClock()
        let rig = makeRig(clock: clock)
        rig.network.setNetworkCondition(.offline, for: [.synthesizeSpeech])
        sendAnswer(rig)
        await showResult(rig)

        await pumpUntil({ rig.vm.readAloudFailure == .explanation }, "a failed read was silent")
        await movesOn(rig, clock, "a failed read held the result")
    }

    /// WHY: Quick quiz and read-aloud off read no explanation, so they must
    /// not spend a speech request on one either.
    @Test("Quick quiz requests no explanation speech")
    func quickQuizRequestsNothing() async {
        let clock = TestClock()
        let rig = makeRig(clock: clock)
        rig.vm.settings.quickGame = true
        sendAnswer(rig)
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(rig.network.synthesizedTexts.isEmpty)
        #expect(rig.vm.explanationSpeechPrefetch == nil)
    }
    /// WHY (#251, founder: "nedáva zmysel zobrazovať tie sekundy, až keď
    /// reálne začne odpočítavať"): while the app reads the verdict and the
    /// explanation the countdown stands still, so "3s" would be a promise the
    /// result does not keep. The seconds appear once they count down.
    @Test("Next shows no seconds while the result is read, and shows them once counting")
    func secondsOnlyWhileCounting() {
        let held = ResultFooter(autoAdvanceActive: true, countdownRemaining: 3, countdownTotal: 3, countdownHeld: true, onNext: {})
        #expect(!held.showsSeconds, "the seconds showed while the app was still speaking")
        let counting = ResultFooter(autoAdvanceActive: true, countdownRemaining: 2, countdownTotal: 3, onNext: {})
        #expect(counting.showsSeconds, "the running countdown lost its seconds")
        let paused = ResultFooter(autoAdvanceActive: false, countdownRemaining: 2, countdownTotal: 3, onNext: {})
        #expect(!paused.showsSeconds)
    }
}
