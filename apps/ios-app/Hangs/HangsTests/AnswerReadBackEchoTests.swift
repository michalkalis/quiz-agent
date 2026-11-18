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
        #expect(silence.isAnswerCaptureActive, "the live sheet keeps the listener's audio")
    }

    /// WHY (screenshots 1–3): the listener heard the read-back "Skipped." and
    /// took it for a new answer. The app's own voice must neither hold the
    /// countdown nor be uploaded, and its audio must not ride along with the
    /// driver's next utterance.
    @Test("the read-back heard by the listener is not a new answer")
    func echoIsNotANewAnswer() async {
        let (vm, silence, network) = makeVM()
        await openSheet(vm, silence, answer: "skipped")

        silence.simulateAnswerAudio(Data(count: 16000))
        silence.simulateCommandTranscript("Skipped", isFinal: false)
        silence.simulateCommandTranscript("Skipped.")
        await drain()
        #expect(network.submitVoiceAnswerCallCount == 0, "the app's own voice was uploaded as a new answer")
        #expect(vm.recordingCoordinator.countdownHold == nil, "the echo held the countdown")
        #expect(vm.autoConfirmCountdown == Config.autoConfirmDelaySecs)
        #expect(vm.transcribedAnswer == "skipped")

        network.mockResponse = response(answer: "Curling")
        silence.simulateAnswerAudio(Data(count: 8000))
        silence.simulateCommandTranscript("carling")
        await pumpUntil({ vm.transcribedAnswer == "Curling" }, "a real new answer after the echo was lost")
        #expect((network.capturedVoiceAnswerBytes ?? 0) < 16000, "the echo's audio rode along with the next answer")
    }

    /// WHY (the loop itself): the on-device recognizer can mishear the echo, so
    /// the upload is the last line. A transcript that is just the answer the
    /// sheet read back is that read-back again — reading it back once more is
    /// what kept the sheet reopening. The sheet keeps its answer and listens.
    @Test("an upload that comes back as the read-back keeps the answer and does not read it again")
    func echoTranscriptDoesNotLoop() async {
        let (vm, silence, network) = makeVM()
        await openSheet(vm, silence, answer: "skipped")
        let readBacks = network.synthesizedTexts.count(where: { $0 == "skipped" })
        network.mockResponse = response(answer: "skipped")

        silence.simulateAnswerAudio(Data(count: 16000))
        silence.simulateCommandTranscript("kicked")
        await pumpUntil { network.submitVoiceAnswerCallCount == 1 }
        await pumpUntil(
            { vm.recordingCoordinator.spokenReplacement == nil && vm.autoConfirmCountdown == Config.autoConfirmDelaySecs },
            "the sheet did not come back to its answer"
        )
        #expect(vm.transcribedAnswer == "skipped")
        #expect(network.synthesizedTexts.count(where: { $0 == "skipped" }) == readBacks, "the echo was read back again: the loop")
        #expect(silence.isAnswerCaptureActive, "the sheet stopped listening")
        #expect(vm.quizState == .processing)
    }

    /// WHY (screenshot 4): "confirm" said while the read-back still sounded
    /// arrived as "Capitalism. Confirm." — a confirm, not a new answer.
    @Test("'confirm' said over the read-back's tail confirms the answer")
    func confirmOverEchoTail() async {
        let (vm, silence, network) = makeVM()
        await openSheet(vm, silence, answer: "Capitalism")

        silence.simulateAnswerAudio(Data(count: 16000))
        silence.simulateCommandTranscript("Capitalism. Confirm.")
        await pumpUntil({ vm.quizState.isShowingResult }, "'confirm' over the echo did not confirm")
        #expect(network.submitVoiceAnswerCallCount == 0, "the echo + confirm was uploaded as a new answer")
    }

    /// WHY (screenshot 4, server side): when only the upload caught the
    /// command, the transcript is the read-back plus "Confirm." — it confirms
    /// the answer on the sheet and never becomes the answer.
    @Test("a 'confirm' the upload heard after the read-back confirms the old answer")
    func confirmGluedToEchoInTranscript() async {
        let (vm, silence, network) = makeVM()
        await openSheet(vm, silence, answer: "Capitalism")
        network.mockResponse = response(answer: "Capitalism. Confirm.")

        silence.simulateAnswerAudio(Data(count: 16000))
        silence.simulateCommandTranscript("the firm")
        await pumpUntil({ network.submitTextInputCallCount == 1 }, "the old answer was not confirmed")
        #expect(network.capturedTextInputInput == "Capitalism")
        #expect(vm.transcribedAnswer != "Capitalism. Confirm.")
    }

    /// WHY: the same merge with a real new answer — the driver's words count,
    /// the echoed old answer in front of them does not. The grade was for the
    /// merged text, so confirming re-grades the new answer alone.
    @Test("a new answer heard after the read-back keeps only the new words")
    func newAnswerAfterEchoDropsTheEcho() async {
        let (vm, silence, network) = makeVM()
        await openSheet(vm, silence, answer: "Capitalism")
        network.mockResponse = response(answer: "Capitalism. Communism.")

        silence.simulateAnswerAudio(Data(count: 16000))
        silence.simulateCommandTranscript("communism")
        await pumpUntil({ vm.transcribedAnswer == "Communism." }, "the echo stayed in the new answer")
        #expect(vm.recordingCoordinator.pendingResponse == nil, "the merged text's grade would be used")

        await vm.recordingCoordinator.confirmAnswer()
        #expect(network.capturedTextInputInput == "Communism.")
    }
}
