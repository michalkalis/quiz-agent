//
//  MCQAnswerByNumberTests.swift
//  HangsTests
//
//  #185 track G — MCQ answers by number (car test 2026-09-23, finding 6).
//
//  The driver said "céčko"; the batch voice path bypassed the on-device
//  matcher and the server's exact match graded it wrong. Founder decisions
//  2026-09-24: options are labelled 1–4 (A–D only when the options are
//  numbers), the server matches every spoken form and is the one grader, and
//  an answer it cannot place is asked again — never marked wrong.
//

import Clocks
import Foundation
@testable import Hangs
import os
import SwiftUI
import Testing
import ViewInspector

private func mcq(labels: [String: String]?) -> Question {
    Question(
        id: "q_mcq", question: "Which planet is the largest?", type: .textMultichoice,
        possibleAnswers: ["a": "Mars", "b": "Jupiter", "c": "Saturn", "d": "Neptune"],
        difficulty: "easy", topic: "Science", category: "adults",
        sourceUrl: nil, sourceExcerpt: nil, mediaUrl: nil, imageSubtype: nil,
        explanation: nil, generatedBy: nil, optionLabels: labels
    )
}

private let numberLabels = ["a": "1", "b": "2", "c": "3", "d": "4"]
private let letterLabels = ["a": "A", "b": "B", "c": "C", "d": "D"]

// MARK: - Wire contract (PR #193)

@Suite("#185 G — MCQ wire contract", .serialized)
struct MCQAnswerWireContractTests {
    private func makeService() -> NetworkService {
        NetworkService(baseURL: "http://test.invalid", session: StubURLProtocol.makeSession())
    }

    /// WHY: every behaviour below is opt-in per session. Without the header the
    /// server keeps grading an unplaced MCQ answer "incorrect" and reads the
    /// options as "a: … b: …" while the screen shows 1–4.
    @Test("session create declares answer-codes and option-labels")
    func sessionCreateDeclaresCapabilities() async throws {
        let captured = OSAllocatedUnfairLock<URLRequest?>(initialState: nil)
        StubURLProtocol.handler = { req in
            captured.withLock { $0 = req }
            return (.make(status: 500), Data())
        }
        defer { StubURLProtocol.handler = nil }

        _ = try? await makeService().createSession()

        let header = try #require(captured.withLock { $0 }?.value(forHTTPHeaderField: "X-Client-Capabilities"))
        let tokens = Set(header.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        #expect(tokens.isSuperset(of: ["answer-codes", "option-labels"]))
    }

    /// WHY: the three "say it again" codes must reach the app as their own
    /// error — a generic 400 message would put an error screen where the
    /// driver should be asked again.
    @Test("a coded 400 on either submit route → .answerNotCaptured", arguments: [
        (#"{"detail":{"code":"mcq_unmatched","message":"m","heard":"b alebo c"}}"#, AnswerRetryCode.mcqUnmatched, "b alebo c" as String?),
        (#"{"detail":{"code":"no_answer","message":"m"}}"#, AnswerRetryCode.noAnswer, nil),
        (#"{"detail":{"code":"no_speech","message":"m"}}"#, AnswerRetryCode.noSpeech, nil),
    ])
    func codedRetryDecodes(body: String, code: AnswerRetryCode, heard: String?) async throws {
        StubURLProtocol.handler = { _ in (.make(status: 400), Data(body.utf8)) }
        defer { StubURLProtocol.handler = nil }
        let service = makeService()

        for route in ["voice", "text"] {
            do {
                if route == "voice" {
                    _ = try await service.submitVoiceAnswer(sessionId: "s1", audioData: Data([1]), fileName: "answer.wav", questionId: "q_mcq")
                } else {
                    _ = try await service.submitTextInput(sessionId: "s1", input: "xyz", audio: false, questionId: "q_mcq")
                }
                Issue.record("\(route): expected a throw")
            } catch let NetworkError.answerNotCaptured(gotCode, gotHeard) {
                #expect(gotCode == code, "\(route)")
                #expect(gotHeard == heard, "\(route)")
            } catch {
                Issue.record("\(route): expected .answerNotCaptured, got \(error)")
            }
        }
    }

    /// WHY: a session created by an older build still gets plain-string 400s;
    /// those keep today's handling.
    @Test("a plain-string 400 stays .serverError(400, …)")
    func legacy400Unchanged() async throws {
        StubURLProtocol.handler = { _ in (.make(status: 400), Data(#"{"detail":"speech not understood"}"#.utf8)) }
        defer { StubURLProtocol.handler = nil }

        do {
            _ = try await makeService().submitTextInput(sessionId: "s1", input: "x", audio: false, questionId: nil)
            Issue.record("expected a throw")
        } catch let NetworkError.serverError(status, message) {
            #expect(status == 400)
            #expect(message == "speech not understood")
        }
    }

    @Test("option_labels decodes on MCQ and is absent on open questions")
    func optionLabelsDecode() throws {
        let json = #"""
        {"id":"q1","question":"?","type":"text_multichoice","difficulty":"easy","topic":"t","category":"adults",
         "possible_answers":{"a":"1969","b":"1970","c":"1971","d":"1972"},
         "option_labels":{"a":"A","b":"B","c":"C","d":"D"}}
        """#
        let question = try JSONDecoder().decode(Question.self, from: Data(json.utf8))
        #expect(question.optionLabels == letterLabels)
        #expect(Question.preview.optionLabels == nil)
    }
}

// MARK: - Labels on screen

@Suite("#185 G — option labels")
@MainActor
struct MCQOptionLabelTests {
    /// WHY: the grid, the result line and the audio must all name an option the
    /// same way, or "say two" means nothing to the driver.
    @Test("the grid shows the server's labels, not the keys")
    func gridShowsServerLabels() async throws {
        let picker = MCQOptionPicker(options: mcq(labels: numberLabels).sortedAnswerOptions, labels: numberLabels, onSelect: { _, _ in })
        try await ViewHosting.host(picker) {
            let tree = try picker.inspect()
            for label in ["1", "2", "3", "4"] {
                #expect(throws: Never.self, "badge \(label)") { try tree.find(text: label) }
            }
            #expect(throws: (any Error).self, "no letter badge on a 1–4 question") { try tree.find(text: "B") }
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "mcq.option.b") }
        }
    }

    @Test("the result line pairs the served label with the option text")
    func resultLineUsesLabels() {
        #expect(mcq(labels: numberLabels).labelledAnswer("Jupiter") == "2 — Jupiter")
        #expect(mcq(labels: numberLabels).labelledAnswer("b") == "2 — Jupiter")
        #expect(mcq(labels: letterLabels).labelledAnswer("Jupiter") == "B — Jupiter")
        // Decoded from before the field existed: the legacy letters, as read out.
        #expect(mcq(labels: nil).labelledAnswer("Jupiter") == "B — Jupiter")
    }

    /// WHY (founder wording 2026-09-24): the retry line asks for what the
    /// options carry — a number on 1–4, a letter on A–D — in every quiz
    /// language; an empty answer keeps the track B line.
    @Test("an unplaced MCQ answer asks for the number or the letter")
    func retryPromptFollowsLabels() {
        #expect(SpokenPrompt.retry(for: .mcqUnmatched, question: mcq(labels: numberLabels)) == .mcqUnmatchedNumber)
        #expect(SpokenPrompt.retry(for: .mcqUnmatched, question: mcq(labels: letterLabels)) == .mcqUnmatchedLetter)
        #expect(SpokenPrompt.retry(for: .noSpeech, question: mcq(labels: numberLabels)) == .didNotCatch)
        #expect(SpokenPrompt.retry(for: .noAnswer, question: nil) == .didNotCatch)

        #expect(SpokenPrompt.mcqUnmatchedNumber.text(language: .slovak) == "Nezachytil som, ktorú možnosť myslíš. Povedz jej číslo.")
        #expect(SpokenPrompt.mcqUnmatchedNumber.text(language: .czech) == "Nezachytil jsem, kterou možnost myslíš. Řekni její číslo.")
        #expect(SpokenPrompt.mcqUnmatchedNumber.text(language: .english) == "I didn't catch which option you meant. Please say its number.")
        #expect(SpokenPrompt.mcqUnmatchedLetter.text(language: .slovak) == "Nezachytil som, ktorú možnosť myslíš. Povedz jej písmeno.")
        #expect(SpokenPrompt.mcqUnmatchedLetter.text(language: .czech) == "Nezachytil jsem, kterou možnost myslíš. Řekni její písmeno.")
        #expect(SpokenPrompt.mcqUnmatchedLetter.text(language: .english) == "I didn't catch which option you meant. Please say its letter.")
    }
}

// MARK: - Asked again, never marked wrong

@Suite("#185 G — an unplaced MCQ answer is asked again")
@MainActor
struct MCQUnmatchedRetryTests {
    private func makeVM(labels: [String: String]) -> (QuizViewModel, MockSilenceDetectionService, MockNetworkService) {
        let silence = MockSilenceDetectionService()
        let audio = MockAudioService()
        audio.playbackDurationNs = 0
        let network = Fixtures.makeFullMockNetwork()
        let vm = QuizViewModel(
            networkService: network,
            audioService: audio,
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: silence,
            sttService: nil,
            clock: AnyClock(TestClock())
        )
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = mcq(labels: labels)
        vm.quizState = .askingQuestion
        return (vm, silence, network)
    }

    private func answer(_ vm: QuizViewModel, _ silence: MockSilenceDetectionService) async {
        silence.simulateAnswerAudio(Data(count: 16000))
        await vm.recordingCoordinator.stopRecordingAndSubmit()
    }

    /// WHY (pinning the car-test regression): "b alebo c" names no single
    /// option. The server graded nothing, so the app says which label to use,
    /// shows the same line, and records the SAME question again; a second miss
    /// is the track B Again / Skip sheet.
    @Test("voice: unplaced → own line + retry on the same question → then Again/Skip")
    func voiceUnmatchedRetriesThenSheet() async {
        let (vm, silence, network) = makeVM(labels: numberLabels)
        network.submitVoiceAnswerError = NetworkError.answerNotCaptured(code: .mcqUnmatched, heard: "b alebo c")

        await vm.toggleRecording()
        await answer(vm, silence)

        await pumpUntil({ vm.quizState == .recording && silence.isAnswerCaptureActive }, "the retry never re-opened the mic")
        #expect(network.synthesizedTexts == [SpokenPrompt.mcqUnmatchedNumber.text(language: .english)])
        #expect(vm.emptyAnswerRetryHintPrompt == .mcqUnmatchedNumber)
        #expect(vm.currentAttempt.questionId == "q_mcq")
        #expect(network.submitTextInputCallCount == 0, "nothing was graded")

        await answer(vm, silence)

        #expect(vm.showAnswerConfirmation)
        #expect(vm.noAnswerCaptured)
        #expect(vm.quizState == .processing)
        #expect(vm.emptyAnswerRetryHintPrompt == nil)
    }

    @Test("voice: on an A–D question the line asks for the letter, on screen too")
    func voiceUnmatchedOnLetterQuestion() async throws {
        let (vm, silence, network) = makeVM(labels: letterLabels)
        network.submitVoiceAnswerError = NetworkError.answerNotCaptured(code: .mcqUnmatched, heard: "dva")

        await vm.toggleRecording()
        await answer(vm, silence)
        await pumpUntil({ vm.quizState == .recording && silence.isAnswerCaptureActive }, "the retry never re-opened the mic")

        #expect(network.synthesizedTexts == [SpokenPrompt.mcqUnmatchedLetter.text(language: .english)])
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "I didn't catch which option you meant. Please say its letter.") }
        }
    }

    /// WHY: a confirmed or edited transcript goes to the text route, which can
    /// refuse it the same way. Before the codes that 400 raised an error screen.
    @Test("text: a refused confirmed transcript is asked again, not an error")
    func textUnmatchedRetries() async {
        let (vm, silence, network) = makeVM(labels: numberLabels)
        network.submitTextInputError = NetworkError.answerNotCaptured(code: .mcqUnmatched, heard: "xyz")

        await vm.resubmitAnswer("xyz")

        await pumpUntil({ vm.quizState == .recording && silence.isAnswerCaptureActive }, "the retry never re-opened the mic")
        #expect(network.synthesizedTexts == [SpokenPrompt.mcqUnmatchedNumber.text(language: .english)])
        #expect(vm.attemptLedger.invariantViolations.isEmpty)
    }
}
