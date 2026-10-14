//
//  RejectedTranscriptRetryTests.swift
//  HangsTests
//
//  #204.2 (founder 2026-10-14): the player says "modrá", the app hears "mokrá",
//  the player asks to record again — and the retry came back "mokrá" again,
//  because nothing told the backend that transcript was already rejected. The
//  retry upload must carry it; a new question must not inherit it; with the
//  diagnostics switch off the upload is today's.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@Suite("Rejected transcript travels with the retry (#204.2)", .serialized)
@MainActor
struct RejectedTranscriptRetryTests {
    private func preservingFlag(_ body: () async throws -> Void) async rethrows {
        let key = VoicePipelineFlags.Key.avoidRejectedTranscriptOnRetry
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        try await body()
    }

    /// A first upload for `q_001` whose transcript ("Test", the mock's) is now
    /// on the confirmation sheet.
    private func answerOnSheet() async -> (QuizViewModel, MockNetworkService) {
        let (vm, network) = Fixtures.makeViewModelWithNetwork(clock: AnyClock(TestClock()))
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        vm.quizState = .askingQuestion
        vm.quizMuteOverride = true
        await vm.recordingCoordinator.submitVoiceAnswer(audioData: Data([0x1, 0x2]))
        #expect(vm.transcribedAnswer == "Test")
        return (vm, network)
    }

    private func rerecordAndSubmitAgain(_ vm: QuizViewModel) async {
        vm.recordingCoordinator.rerecordAnswer()
        await pumpUntil({ vm.quizState != .processing }, "re-record never left the sheet")
        await vm.recordingCoordinator.submitVoiceAnswer(audioData: Data([0x3, 0x4]))
    }

    @Test("re-recording sends the rejected transcript with the next upload")
    func rerecordSendsRejectedTranscript() async {
        await preservingFlag {
            VoicePipelineFlags.avoidRejectedTranscriptOnRetry = true
            let (vm, network) = await answerOnSheet()

            await rerecordAndSubmitAgain(vm)

            #expect(network.capturedVoiceAnswerRejectedTranscripts == [[], ["Test"]],
                    "the first attempt has nothing to avoid; the retry must name what the player rejected")
        }
    }

    @Test("Cancel on the sheet also counts as a rejection")
    func cancelCountsAsRejection() async {
        await preservingFlag {
            VoicePipelineFlags.avoidRejectedTranscriptOnRetry = true
            let (vm, network) = await answerOnSheet()

            vm.recordingCoordinator.cancelProcessing()
            await vm.recordingCoordinator.submitVoiceAnswer(audioData: Data([0x3, 0x4]))

            #expect(network.capturedVoiceAnswerRejectedTranscripts.last == ["Test"])
        }
    }

    @Test("the next question starts without the previous question's rejections")
    func nextQuestionStartsClean() async {
        await preservingFlag {
            VoicePipelineFlags.avoidRejectedTranscriptOnRetry = true
            let (vm, network) = await answerOnSheet()
            vm.recordingCoordinator.rerecordAnswer()
            await pumpUntil({ vm.quizState != .processing }, "re-record never left the sheet")

            vm.currentQuestion = Fixtures.makeQuestion(id: "q_002")
            await vm.recordingCoordinator.submitVoiceAnswer(audioData: Data([0x3, 0x4]))

            #expect(network.capturedVoiceAnswerRejectedTranscripts.last == [],
                    "a word rejected on question 1 may be the right answer to question 2")
        }
    }

    @Test("with the switch off the retry upload is today's")
    func switchOffSendsNothing() async {
        await preservingFlag {
            VoicePipelineFlags.avoidRejectedTranscriptOnRetry = false
            let (vm, network) = await answerOnSheet()

            await rerecordAndSubmitAgain(vm)

            #expect(network.capturedVoiceAnswerRejectedTranscripts == [[], []])
        }
    }

    @Test("the list keeps the newest five, trimmed to 200 characters, without duplicates")
    func listHonoursContractCaps() {
        var list = RejectedTranscripts()
        for word in ["a", "b", "c", "d", "e", "f", "B"] {
            list.add(word, questionKey: "q")
        }
        list.add(String(repeating: "x", count: 250), questionKey: "q")

        let sent = list.transcripts(for: "q")
        #expect(sent.count == RejectedTranscripts.maxCount, "the backend caps the field; more is dropped there anyway")
        #expect(sent.first == "d", "the oldest rejections go first")
        #expect(sent.filter { $0.lowercased() == "b" } == ["B"], "a repeat counts once, as the newest")
        #expect(sent.last?.count == RejectedTranscripts.maxLength)
        #expect(list.transcripts(for: "other").isEmpty)
    }

    @Test("the length cap counts what the backend counts, so a decomposed transcript never earns a 400")
    func lengthCapCountsUnicodeScalars() {
        // "á" as a + combining acute: 1 Swift Character, 2 Python characters.
        var list = RejectedTranscripts()
        list.add(String(repeating: "a\u{301}", count: 150), questionKey: "q")

        let sent = list.transcripts(for: "q")
        #expect(sent.first?.unicodeScalars.count == RejectedTranscripts.maxLength,
                "the backend rejects any item over 200 characters, and that 400 loses the answer")
    }
}
