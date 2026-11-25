//
//  SpokenLineEchoTests.swift
//  HangsTests
//
//  #243.4 — TF drive 2026-11-23 on the phone's built-in mic: the answer came
//  back as "Skús to znova. Parmezán." — the tail of the app's own retry hint
//  in front of the player's answer. Whatever the cause in the room, the app
//  knows what it said right before the mic opened: a transcript that starts
//  with a run of that line loses the run before it is graded, and a transcript
//  that is only the line is no answer at all.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@Suite("#243.4 the app's own last line is never the answer")
@MainActor
struct SpokenLineEchoTests {
    private static let hint = SpokenPrompt.didNotCatch.text(language: .slovak)

    private func strip(_ transcript: String, line: String = hint) -> String {
        RecordingCoordinator.strippingSpokenLineEcho(transcript, line: line, language: .slovak)
    }

    // MARK: - The logged examples

    @Test("the hint's tail in front of the answer is dropped")
    func hintTail() {
        #expect(strip("Skús to znova. Parmezán.") == "Parmezán.")
    }

    @Test("the whole hint, misheard by a letter, in front of the answer is dropped")
    func wholeHint() {
        #expect(strip("Odpoveď sa nepodarilo zachytiť, skúš to znova. Martin Luther King.") == "Martin Luther King.")
    }

    @Test("a piece from the middle of the hint and nothing else is no answer")
    func hintOnly() {
        #expect(strip("Podarilo zachytiť, skús to.") == "")
    }

    // MARK: - What must stay an answer

    /// WHY: an MCQ answer is often one short word that the offer line also
    /// says ("a"); one short word is never taken for the echo.
    @Test("a lone short word the line also contains stays the answer")
    func loneShortWordStays() {
        let offer = PhasePrompt.noAnswerOffer.text(language: .slovak)
        #expect(strip("A.", line: offer) == "A.")
        #expect(strip("To je Paríž.") == "To je Paríž.")
    }

    @Test("an answer that does not start with the line is untouched")
    func unrelatedAnswer() {
        #expect(strip("Parmezán.") == "Parmezán.")
    }

    @Test("a one-word line („Odpovedaj.“) heard in front of the answer is dropped")
    func answerCue() {
        #expect(strip("Odpovedaj. Paríž.", line: PhasePrompt.answer.text(language: .slovak)) == "Paríž.")
    }

    // MARK: - The clip texts match the clips

    /// WHY: the clips are generated from `scripts/generate_phase_prompts.py`;
    /// the echo guard reads the same lines from `PhasePrompt.text`. A line
    /// changed in one place only would stop the guard from recognising it.
    @Test("PhasePrompt texts match the generator script", arguments: [PhasePrompt.answer, .noAnswerOffer, .noAnswerOfferShort])
    func textsMatchScript(_ prompt: PhasePrompt) throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // HangsTests
            .deletingLastPathComponent() // Hangs
            .deletingLastPathComponent() // ios-app
            .deletingLastPathComponent() // apps
            .deletingLastPathComponent() // repo
            .appendingPathComponent("scripts/generate_phase_prompts.py")
        let source = try String(contentsOf: script, encoding: .utf8)
        let block = try #require(source.components(separatedBy: "\"\(prompt.resourceName)\": {").dropFirst().first)
            .components(separatedBy: "}").first ?? ""
        for language in CommandLanguage.allCases {
            #expect(block.contains("\"\(language.rawValue)\": \"\(prompt.text(language: language))\""),
                    "\(prompt.resourceName).\(language.rawValue)")
        }
    }

    // MARK: - End to end

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
        vm.currentSession = Fixtures.makeActiveSession(language: "sk")
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        vm.quizState = .askingQuestion
        vm.recordingCoordinator.speechStartWindow = 60
        vm.recordingCoordinator.deadAirCap = 60
        return (vm, silence, network)
    }

    /// A heard miss: the hint is said, the retry recording opens.
    private func heardMissThenRetry(_ vm: QuizViewModel, _ silence: MockSilenceDetectionService, _ network: MockNetworkService) async {
        network.submitVoiceAnswerError = NetworkError.serverError(statusCode: 400, message: "speech not understood")
        await vm.toggleRecording()
        vm.recordingCoordinator.noteSpeechStarted()
        silence.simulateAnswerAudio(Data(count: 16000))
        await vm.recordingCoordinator.stopRecordingAndSubmit()
        await pumpUntil({ vm.quizState == .recording && silence.isAnswerCaptureActive }, "the retry never re-opened the mic")
        network.submitVoiceAnswerError = nil
    }

    private func response(answer: String) -> QuizResponse {
        QuizResponse(
            success: true,
            message: "Answered",
            session: Fixtures.makeQuizSession(id: "test_session_123", phase: "asking"),
            currentQuestion: Fixtures.makeQuestion(id: "q_002", text: "Next?", source: "Next"),
            evaluation: Evaluation(
                userAnswer: answer, result: .incorrect, points: 0,
                correctAnswer: "Parmezán", questionId: "q_001", explanation: nil
            ),
            feedbackReceived: [],
            audio: nil
        )
    }

    /// WHY (the logged drive): the sheet must show the player's word, and the
    /// grade of the merged text must not stand — confirming re-grades it.
    @Test("after the hint, 'Skús to znova. Parmezán.' reaches the sheet as 'Parmezán.'")
    func retryTranscriptLosesTheHint() async {
        let (vm, silence, network) = makeVM()
        await heardMissThenRetry(vm, silence, network)
        network.mockResponse = response(answer: "Skús to znova. Parmezán.")

        vm.recordingCoordinator.noteSpeechStarted()
        silence.simulateAnswerAudio(Data(count: 16000))
        await vm.recordingCoordinator.stopRecordingAndSubmit()

        await pumpUntil({ vm.showAnswerConfirmation }, "no sheet")
        #expect(vm.transcribedAnswer == "Parmezán.")
        #expect(vm.recordingCoordinator.pendingResponse == nil, "the merged text's grade would be used")
    }

    /// WHY: a recording that heard only the app is no answer — and it must
    /// not be met with the hint again, which the mic would hear again.
    @Test("a transcript that is only the hint is no answer, without another hint")
    func echoOnlyIsNoAnswer() async {
        let (vm, silence, network) = makeVM()
        await heardMissThenRetry(vm, silence, network)
        let hints = network.synthesizedTexts.count
        network.mockResponse = response(answer: "Podarilo zachytiť, skús to.")

        vm.recordingCoordinator.noteSpeechStarted()
        silence.simulateAnswerAudio(Data(count: 16000))
        await vm.recordingCoordinator.stopRecordingAndSubmit()

        await pumpUntil({ vm.noAnswerCaptured && vm.showAnswerConfirmation }, "the echo was not treated as no answer")
        #expect(vm.transcribedAnswer.isEmpty)
        #expect(network.synthesizedTexts.count == hints, "the hint was said again")
    }
}
