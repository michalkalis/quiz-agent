//
//  AnswerReadBackEchoTests.swift
//  HangsTests
//
//  Car test 2026-10-30 (TestFlight build 81): the answer sheet heard its own
//  read-back. Car speakers on Bluetooth media run without echo cancellation and
//  keep playing after the phone has finished the clip, so the sheet's listener
//  (#185 5.1: anything said that is not a command is a new answer) picked up
//  the read-back — "Skipped." — uploaded it, got "skipped" back, read THAT back
//  and heard it again: the sheet reopened until the founder tapped Confirm.
//  When he said "confirm" over the tail, the echo and the command arrived as
//  one utterance, "Capitalism. Confirm.", and became the new answer.
//  The words the app just read back are the app's voice, never the driver's.
//  #243.5 (founder 2026-11-24): the sheet listens for "again" only, so
//  nothing said on it is uploaded any more; what stays is the listener's
//  echo guard — the echo holds nothing, and "again" over it still counts.
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

@MainActor
private func response(answer: String) -> QuizResponse {
    QuizResponse(
        success: true,
        message: "Answered",
        session: Fixtures.makeQuizSession(id: "test_session_123", phase: "asking"),
        currentQuestion: Fixtures.makeQuestion(id: "q_002", text: "Next?", source: "Next"),
        evaluation: Evaluation(
            userAnswer: answer, result: .correct, points: 1.0,
            correctAnswer: answer, questionId: "q_001", explanation: nil
        ),
        feedbackReceived: ["answer: correct"],
        audio: nil
    )
}

@Suite("Car test 2026-10-30: the answer sheet never answers its own read-back")
@MainActor
struct AnswerReadBackEchoTests {
    private func makeVM() -> (QuizViewModel, MockSilenceDetectionService, MockNetworkService) {
        let silence = MockSilenceDetectionService()
        let audio = MockAudioService()
        audio.playbackDurationNs = 0
        let network = Fixtures.makeFullMockNetwork()
        let vm = QuizViewModel(
            networkService: network,
            audioService: audio,
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: silence,
            clock: AnyClock(TestClock())
        )
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        return (vm, silence, network)
    }

    /// The sheet for a recorded answer, read back, listener live, counting down.
    private func openSheet(_ vm: QuizViewModel, _ silence: MockSilenceDetectionService, answer: String) async {
        vm.quizState = .processing
        vm.recordingCoordinator.pendingResponse = response(answer: answer)
        vm.recordingCoordinator.presentVoiceTranscript(answer)
        await pumpUntil({ vm.autoConfirmCountdown == Config.autoConfirmDelaySecs }, "the countdown never started")
        #expect(silence.isListening, "the sheet listens for \"again\"")
    }

    /// WHY (screenshots 1–3): the listener heard the read-back "Skipped." The
    /// app's own voice must neither hold the countdown nor be uploaded.
    @Test("the read-back heard by the listener holds nothing and is not uploaded")
    func echoIsNothing() async {
        let (vm, silence, network) = makeVM()
        await openSheet(vm, silence, answer: "skipped")

        silence.simulateAnswerAudio(Data(count: 16000))
        silence.simulateCommandTranscript("Skipped", isFinal: false)
        silence.simulateCommandTranscript("Skipped.")
        await drain()
        #expect(network.submitVoiceAnswerCallCount == 0, "the app's own voice was uploaded")
        #expect(vm.recordingCoordinator.countdownHold == nil, "the echo held the countdown")
        #expect(vm.autoConfirmCountdown == Config.autoConfirmDelaySecs)
        #expect(vm.transcribedAnswer == "skipped")
    }

    /// WHY (the loop itself): a misheard echo ("kicked") used to be uploaded,
    /// come back as the answer, and be read back again. #243.5: it is no
    /// answer at all — nothing uploaded, nothing read again, still listening.
    @Test("a misheard echo is not uploaded and not read back again")
    func misheardEchoDoesNotLoop() async {
        let (vm, silence, network) = makeVM()
        await openSheet(vm, silence, answer: "skipped")
        let readBacks = network.synthesizedTexts.count(where: { $0 == "skipped" })

        silence.simulateAnswerAudio(Data(count: 16000))
        silence.simulateCommandTranscript("kicked")
        await pumpUntil({ vm.autoConfirmCountdown == Config.autoConfirmDelaySecs }, "the countdown never resumed")
        #expect(network.submitVoiceAnswerCallCount == 0)
        #expect(network.synthesizedTexts.count(where: { $0 == "skipped" }) == readBacks, "the echo was read back again")
        #expect(silence.isListening, "the sheet stopped listening")
        #expect(vm.quizState == .processing)
    }

    /// WHY (screenshot 4, founder 2026-11-22): "confirm" said over the
    /// read-back's tail arrived as "Capitalism. Confirm.". The spoken confirm
    /// is gone and (#243.5) the rest is no answer: the old one stands.
    @Test("'confirm' said over the read-back's tail changes nothing")
    func confirmOverEchoTailChangesNothing() async {
        let (vm, silence, network) = makeVM()
        await openSheet(vm, silence, answer: "Capitalism")

        silence.simulateAnswerAudio(Data(count: 16000))
        silence.simulateCommandTranscript("Capitalism. Confirm.")
        await drain()
        #expect(network.submitVoiceAnswerCallCount == 0)
        #expect(!vm.quizState.isShowingResult, "'confirm' still confirms the answer")
        #expect(vm.transcribedAnswer == "Capitalism")
    }

    /// WHY: the echo guard strips the read-back's words before matching, so
    /// "again" said over the tail ("Capitalism. Again.") is still the command.
    @Test("'again' said over the read-back's tail still records again")
    func againOverEchoTail() async {
        let (vm, silence, _) = makeVM()
        await openSheet(vm, silence, answer: "Capitalism")

        silence.simulateCommandTranscript("Capitalism. Again.")
        await pumpUntil({ vm.quizState == .recording }, "'again' over the echo was lost")
    }
}
