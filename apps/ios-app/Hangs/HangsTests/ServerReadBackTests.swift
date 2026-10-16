//
//  ServerReadBackTests.swift
//  HangsTests
//
//  #208.3 — the "you said" read-back synthesized by the server while it grades
//  the voice answer, returned as `QuizResponse.readBack`. Why these matter:
//  - It is asked for only when it will be played (not muted): synthesis is paid
//    per character, so a muted driver must not cost a TTS call per answer.
//  - It is played only when it speaks exactly what the sheet shows; anything
//    else (absent, another text, bad audio) falls back to `synthesizeSpeech`,
//    so the driver never hears a different answer than the one being graded.
//  - It is an optional speed-up: a malformed `read_back` must never cost the
//    answer itself (the response must still decode).
//

import Foundation
@testable import Hangs
import Testing

@Suite("#208.3 server read-back")
@MainActor
struct ServerReadBackTests {
    private static let serverAudio = Data([0x4F, 0x67, 0x67, 0x53])

    private func makeVM(readBack: ReadBackAudio? = nil)
        -> (QuizViewModel, MockSilenceDetectionService, MockNetworkService, MockAudioService)
    {
        let silence = MockSilenceDetectionService()
        let audio = MockAudioService()
        audio.playbackDurationNs = 0
        let network = Fixtures.makeFullMockNetwork()
        if let base = network.mockResponse {
            network.mockResponse = QuizResponse(
                success: base.success,
                message: base.message,
                session: base.session,
                currentQuestion: base.currentQuestion,
                evaluation: base.evaluation,
                feedbackReceived: base.feedbackReceived,
                audio: base.audio,
                readBack: readBack
            )
        }
        let vm = QuizViewModel(
            networkService: network,
            audioService: audio,
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: silence
        )
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Fixtures.makeQuestion()
        vm.quizState = .askingQuestion
        return (vm, silence, network, audio)
    }

    private func answerByVoice(_ vm: QuizViewModel, _ silence: MockSilenceDetectionService) async {
        await vm.recordingCoordinator.startRecording()
        silence.simulateAnswerAudio(Data(count: 16000))
        await vm.recordingCoordinator.stopRecordingAndSubmit()
    }

    @Test("the upload asks for the read-back only when it will be played")
    func readBackRequestedOnlyWhenNotMuted() async {
        let (vm, silence, network, _) = makeVM()
        await answerByVoice(vm, silence)
        #expect(network.capturedVoiceAnswerReadBack == [true])

        let (mutedVM, mutedSilence, mutedNetwork, _) = makeVM()
        mutedVM.settings.isMuted = true
        await answerByVoice(mutedVM, mutedSilence)
        #expect(mutedNetwork.capturedVoiceAnswerReadBack == [false], "a muted driver must not pay for synthesis")
    }

    @Test("a read-back of exactly the sheet's text is played and no TTS is requested")
    func matchingReadBackIsPlayed() async {
        let readBack = ReadBackAudio(text: "Test", audioBase64: Self.serverAudio.base64EncodedString(), format: "opus")
        let (vm, silence, network, audio) = makeVM(readBack: readBack)

        await answerByVoice(vm, silence)

        #expect(vm.transcribedAnswer == "Test")
        await pumpUntil({ audio.playOpusCallCount == 1 }, "read-back never played")
        #expect(audio.lastPlayedData == Self.serverAudio, "the server's audio is what gets spoken")
        #expect(network.synthesizedTexts.isEmpty, "no second synthesis round trip")
        await pumpUntil({ !vm.isPlayingAnswerReadBack }, "read-back never finished")
        #expect(vm.autoConfirmCountdown == Config.autoConfirmDelaySecs, "auto-confirm still arms after it")
    }

    @Test("a read-back of another text falls back to synthesizing the sheet's text")
    func mismatchedReadBackFallsBack() async {
        let readBack = ReadBackAudio(text: "Tests", audioBase64: Self.serverAudio.base64EncodedString(), format: "opus")
        let (vm, silence, network, audio) = makeVM(readBack: readBack)

        await answerByVoice(vm, silence)

        await pumpUntil({ audio.playOpusCallCount == 1 }, "read-back never played")
        #expect(network.synthesizedTexts == ["Test"])
        #expect(audio.lastPlayedData != Self.serverAudio, "audio of another text must never be spoken")
    }

    @Test("no read-back in the response falls back to synthesizing the sheet's text")
    func absentReadBackFallsBack() async {
        let (vm, silence, network, audio) = makeVM()

        await answerByVoice(vm, silence)

        await pumpUntil({ audio.playOpusCallCount == 1 }, "read-back never played")
        #expect(network.synthesizedTexts == ["Test"])
    }

    @Test("only a read-back of the exact sheet text with decodable audio is used")
    func preparedReadBackAudio() {
        let audio = Self.serverAudio.base64EncodedString()
        #expect(RecordingCoordinator.preparedReadBackAudio(nil, for: "Paris") == nil)
        #expect(RecordingCoordinator.preparedReadBackAudio(
            ReadBackAudio(text: "paris", audioBase64: audio, format: "opus"), for: "Paris"
        ) == nil, "the sheet text, exactly")
        #expect(RecordingCoordinator.preparedReadBackAudio(
            ReadBackAudio(text: "Paris", audioBase64: "%%not base64%%", format: "opus"), for: "Paris"
        ) == nil, "undecodable audio falls back to TTS")
        #expect(RecordingCoordinator.preparedReadBackAudio(
            ReadBackAudio(text: "Paris", audioBase64: audio, format: "opus"), for: "Paris"
        ) == Self.serverAudio)
    }

    // MARK: - Wire shape

    private func decodeResponse(readBackField: String?) throws -> QuizResponse {
        let field = readBackField.map { #","read_back":\#($0)"# } ?? ""
        let json = """
        {"success":true,"message":"ok","session":{"session_id":"s1","mode":"single","phase":"asking","max_questions":5,
          "current_difficulty":"random","category":null,"language":"sk","participants":[],
          "expires_at":"2026-10-15T12:00:00Z","created_at":"2026-10-15T11:00:00Z"},
         "current_question":null,"evaluation":null,"feedback_received":[]\(field)}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(QuizResponse.self, from: Data(json.utf8))
    }

    @Test("QuizResponse decodes read_back; absent means nil")
    func decodesReadBack() throws {
        let response = try decodeResponse(readBackField: #"{"text":"Paris","audio_base64":"T2dnUw==","format":"opus"}"#)
        #expect(response.readBack == ReadBackAudio(text: "Paris", audioBase64: "T2dnUw==", format: "opus"))
        #expect(try decodeResponse(readBackField: nil).readBack == nil)
    }

    @Test("a malformed read_back decodes as nil and never loses the answer")
    func malformedReadBackIsDropped() throws {
        let response = try decodeResponse(readBackField: #"{"text":42}"#)
        #expect(response.readBack == nil)
        #expect(response.success)
        #expect(response.session.id == "s1")
    }
}
