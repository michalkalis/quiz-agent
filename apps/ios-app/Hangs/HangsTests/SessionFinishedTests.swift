//
//  SessionFinishedTests.swift
//  HangsTests
//
//  #189 — TF feedback 2026-09-29. The answer that ends a set is graded before
//  the driver confirms it, so the server session is already FINISHED while the
//  confirmation sheet is up. "Again" re-recorded, every upload came back as a
//  plain 400 the app read as "didn't catch that" (a retry loop), and the Skip
//  on the empty sheet then raised the "couldn't submit your answer" screen.
//
//  The server now says `session_finished`; whatever path hears it, the set is
//  over and the app must land on the results — never ask again, never show an
//  error.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

// MARK: - Wire contract

@Suite("#189 — session_finished wire contract", .serialized)
struct SessionFinishedWireContractTests {
    /// WHY: the code must reach the app as its own error. Decoded as a generic
    /// 400 it is exactly the loop the founder hit on the voice path.
    @Test("a coded session_finished 400 on either submit route → .sessionFinished")
    func codedSessionFinishedDecodes() async throws {
        let body = #"{"detail":{"code":"session_finished","message":"Not waiting for input"}}"#
        StubURLProtocol.handler = { _ in (.make(status: 400), Data(body.utf8)) }
        defer { StubURLProtocol.handler = nil }
        let service = NetworkService(baseURL: "http://test.invalid", session: StubURLProtocol.makeSession())

        for route in ["voice", "text"] {
            do {
                if route == "voice" {
                    _ = try await service.submitVoiceAnswer(sessionId: "s1", audioData: Data([1]), fileName: "answer.wav", questionId: "q_010")
                } else {
                    _ = try await service.submitTextInput(sessionId: "s1", input: "skip", audio: false, questionId: "q_010")
                }
                Issue.record("\(route): expected a throw")
            } catch NetworkError.sessionFinished {
                // expected
            } catch {
                Issue.record("\(route): expected .sessionFinished, got \(error)")
            }
        }
    }
}

// MARK: - The set ends into the results

@Suite("#189 — a set the server already ended lands on the results")
@MainActor
struct SessionFinishedFlowTests {
    private func makeVM() -> (QuizViewModel, MockSilenceDetectionService, MockNetworkService) {
        let silence = MockSilenceDetectionService()
        let audio = MockAudioService()
        audio.playbackDurationNs = 0
        let network = Fixtures.makeFullMockNetwork()
        // #180 track A: nobody advances this clock — no timeout or countdown
        // can fire underneath the flow.
        let vm = QuizViewModel(
            networkService: network,
            audioService: audio,
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: silence,
            sttService: nil,
            clock: AnyClock(TestClock())
        )
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_010", text: "Which planet is the farthest from the Sun?")
        vm.quizState = .askingQuestion
        return (vm, silence, network)
    }

    /// The server's answer to the set's last question: graded, session
    /// finished, no next question.
    private func finishedResponse() -> QuizResponse {
        QuizResponse(
            success: true,
            message: "Quiz completed!",
            session: Fixtures.makeQuizSession(phase: "finished"),
            currentQuestion: nil,
            evaluation: Evaluation(
                userAnswer: "Neptún",
                result: .incorrect,
                points: 0,
                correctAnswer: "Saturn",
                questionId: "q_010",
                explanation: nil
            ),
            feedbackReceived: ["answer: incorrect"],
            audio: nil
        )
    }

    private func answer(_ vm: QuizViewModel, _ silence: MockSilenceDetectionService) async {
        silence.simulateAnswerAudio(Data(count: 16000))
        await vm.recordingCoordinator.stopRecordingAndSubmit()
    }

    /// WHY (the founder's Q8 "Neptún"): the last answer ended the set, "again"
    /// re-recorded, and the re-upload was refused. That is the end of the set —
    /// asking "didn't catch that" again or opening the Again/Skip sheet only
    /// loops the driver on a question the server no longer has open.
    @Test("re-answer after the set ended → results, no Again/Skip sheet, no error")
    func rerecordAfterFinishLandsOnResults() async {
        let (vm, silence, network) = makeVM()
        network.mockResponse = finishedResponse()

        await vm.toggleRecording()
        await answer(vm, silence)
        #expect(vm.showAnswerConfirmation, "the set's last answer waits on the confirmation sheet")

        vm.recordingCoordinator.rerecordAnswer()
        await pumpUntil({ vm.quizState == .recording && silence.isAnswerCaptureActive }, "the re-record never opened the mic")

        network.submitVoiceAnswerError = NetworkError.sessionFinished
        await answer(vm, silence)

        #expect(vm.quizState == .finished)
        #expect(vm.showAnswerConfirmation == false, "no sheet over a set that is over")
        #expect(vm.noAnswerCaptured == false)
        #expect(vm.activeErrorModel == nil, "no 'couldn't submit your answer' screen")
        #expect(vm.errorMessage == nil)
        #expect(vm.emptyAnswerRetryHintPrompt == nil, "no 'didn't catch that' retry")
        #expect(network.submitVoiceAnswerCallCount == 2)
        #expect(vm.attemptLedger.invariantViolations.isEmpty)
    }

    /// WHY (the founder's error screen): Skip on the empty sheet sent a skip for
    /// a question the finished set no longer has open. The set is over, so the
    /// skip ends it into the results like the normal last question does.
    @Test("Skip on the empty sheet after the set ended → results, not the error screen")
    func skipAfterFinishLandsOnResults() async {
        let (vm, _, network) = makeVM()
        network.submitTextInputError = NetworkError.sessionFinished
        // The Again/Skip sheet with nothing captured, as the founder had it.
        vm.quizState = .processing
        vm.transcribedAnswer = ""
        vm.noAnswerCaptured = true
        vm.showAnswerConfirmation = true

        await vm.confirmAnswer()

        #expect(network.capturedTextInputInput == "skip")
        #expect(vm.quizState == .finished)
        #expect(vm.activeErrorModel == nil, "no 'couldn't submit your answer' screen")
        #expect(vm.errorMessage == nil)
        #expect(vm.showAnswerConfirmation == false)
    }
}
