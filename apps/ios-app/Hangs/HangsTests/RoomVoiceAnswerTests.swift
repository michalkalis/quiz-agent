//
//  RoomVoiceAnswerTests.swift
//  HangsTests
//
//  #249.5 (founder 2026-11-26): in a game together every player answers a
//  typed-answer question by voice with solo's controls, and the answer time
//  is solo's bar under the question. Why it matters: one recording is one
//  answer (never a second one from the typed draft or a double tap); a
//  recording running when the shared time hits zero is the player's answer
//  and must be sent; and whatever the network or the microphone does, the
//  player sees progress or a clear note, can still type, and the game goes on.
//  Time is the injected clock; the server is the scripted mock room.
//

import Clocks
import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@Suite("Game together: answers by voice like solo (#249.5)")
@MainActor
struct RoomVoiceAnswerTests {
    private let rooms = MockRoomService()
    private let network = MockNetworkService()
    private let audio = MockAudioService()
    private let clock = TestClock<Duration>()

    /// Answers stored for the typed question (the tapped first one is dropped).
    private var typedQuestionAnswers: [String] { Array(rooms.answers.dropFirst()) }

    private func settle() async {
        for _ in 0 ..< 100 {
            await Task.yield()
        }
    }

    /// A guest at the typed second question, 20 s of answer time from now.
    private func guestAtTypedQuestion(silence: MockSilenceDetectionService? = nil) async -> RoomViewModel {
        network.mockSession = QuizResponse.previewStartQuiz.session
        network.mockResponse = .previewStartQuiz
        rooms.conditions.networkClock = AnyClock(clock)
        let model = RoomViewModel(
            rooms: rooms, network: network, audio: audio, solo: .default, deviceId: "device",
            accountName: "Jana",
            names: PlayerNameStore(defaults: UserDefaults(suiteName: "room-voice-\(UUID().uuidString)")!),
            settingsStore: MultiplayerSettingsStore(defaults: UserDefaults(suiteName: "room-voice-rules-\(UUID().uuidString)")!),
            clock: AnyClock(clock), languageCode: "sk", isOffCellular: { true },
            pendingLeaves: PendingRoomLeaveStore(defaults: UserDefaults(suiteName: "room-voice-leave-\(UUID().uuidString)")!),
            silence: silence
        )
        await model.join(.token(MockRoomService.token))
        rooms.hostStarts()
        await model.refresh()
        await model.guestReadTask?.value
        await model.submitOption(key: "b")
        rooms.hostMovesOn()
        await model.refresh()
        await model.guestReadTask?.value
        #expect(model.question?.id == "mq2")
        #expect(model.canSpeak)
        return model
    }

    /// Opens the mic and "says" a second of audio.
    private func speak(_ model: RoomViewModel) async {
        await model.toggleRecording()
        #expect(model.voicePhase == .recording)
        audio.emitStreamingChunk(Data(count: 32000))
    }

    // MARK: - Solo's controls

    // WHY: the founder asked for solo's buttons so nobody has to learn a new
    // layout: Answer (mic) and Type on a typed-answer question, solo's bar
    // under the question, and no seconds label in the players' strip any more.
    @Test("a typed-answer question shows solo's Answer, Type and bar; the strip has no timer")
    func soloControls() async throws {
        let model = await guestAtTypedQuestion()
        defer { model.stopAll() }
        let view = try RoomQuestionView(viewModel: model).inspect()
        for id in ["room.answer.record", "room.answer.type", "room.question.bar"] {
            #expect(throws: Never.self, "missing \(id)") { try view.find(viewWithAccessibilityIdentifier: id) }
        }
        #expect(throws: (any Error).self) { try view.find(viewWithAccessibilityIdentifier: "room.question.timer") }
        #expect(model.listenPhase == .thinking(remaining: 20, total: 20))
    }

    // WHY: A–D stays a tap, as in solo's option grid; a mic there would be a
    // second way to answer the server does not take.
    @Test("an option question has no mic")
    func optionsAreTapped() async {
        network.mockSession = QuizResponse.previewStartQuiz.session
        rooms.conditions.networkClock = AnyClock(clock)
        let model = RoomViewModel(
            rooms: rooms, network: network, audio: audio, solo: .default, deviceId: "device",
            names: PlayerNameStore(defaults: UserDefaults(suiteName: "room-voice-mcq-\(UUID().uuidString)")!),
            clock: AnyClock(clock), languageCode: "sk", isOffCellular: { true }
        )
        defer { model.stopAll() }
        await model.join(.token(MockRoomService.token))
        rooms.hostStarts()
        await model.refresh()
        #expect(model.question?.isMultipleChoice == true)
        #expect(!model.canSpeak)
        await model.toggleRecording()
        #expect(model.voicePhase == .idle && audio.micPermissionRequestCount == 0)
    }

    // MARK: - Ends on silence, like solo

    // WHY: the founder wants the room's mic to behave like solo's: the player
    // just speaks and stops, and the VAD's silence after speech sends the
    // answer with no tap on Stop. It is solo's engine and solo's blip bar, so
    // a threshold change in solo changes the room too.
    @Test("silence after speech sends the answer once, on solo's engine and blip bar")
    func silenceAfterSpeechSends() async {
        let silence = MockSilenceDetectionService()
        let model = await guestAtTypedQuestion(silence: silence)
        defer { model.stopAll() }
        await model.toggleRecording()
        #expect(model.voicePhase == .recording)
        #expect(silence.isAnswerCaptureActive)
        #expect(silence.answerDetectionMinSpeechDurations == [VADTuning.minSpeechDurationSecs])
        silence.simulateSilenceEvent(.speechStarted)
        silence.simulateAnswerAudio(Data(count: 32000))
        silence.simulateSilenceEvent(.silenceAfterSpeech(duration: 1.2))
        await settle()

        #expect(rooms.voiceUploads.count == 1)
        #expect(model.round?.yourAnswer == "Canberra")
        #expect(model.voicePhase == .idle && !silence.isAnswerCaptureActive)
        // The recording started the engine, so it stops it again (solo's rule).
        #expect(!silence.isListening)
        // A late event of the finished recording sends nothing more.
        silence.simulateSilenceEvent(.silenceAfterSpeech(duration: 1.2))
        await settle()
        #expect(rooms.voiceUploads.count == 1)
    }

    // WHY: solo's 5 s "time to start speaking": a mic nobody speaks into ends
    // with solo's "Didn't catch that", sends nothing, and the player can try
    // again or type before the time is up.
    @Test("no speech within solo's start window ends the recording unsent")
    func noSpeechEndsUnsent() async {
        let silence = MockSilenceDetectionService()
        let model = await guestAtTypedQuestion(silence: silence)
        defer { model.stopAll() }
        await model.toggleRecording()
        await clock.advance(by: .seconds(Config.speechStartWindow) - .milliseconds(100))
        await settle()
        #expect(model.voicePhase == .recording, "ended before solo's window")

        await clock.advance(by: .milliseconds(100))
        await settle()
        #expect(model.voicePhase == .idle && model.voiceNote == .didNotCatch)
        #expect(rooms.voiceUploads.isEmpty && !silence.isListening)
        #expect(model.canSpeak, "the question stays open for another try")
    }

    // WHY: solo never cuts a late or quiet answer on a detector that cannot
    // vouch for the silence (#185), and a player already speaking is never
    // cut by the start window; the shared time then decides, and sends.
    @Test(
        "the start window does not end a recording the detector heard or cannot vouch for",
        arguments: [true, false]
    )
    func startWindowKeepsSpeaker(heardSpeech: Bool) async {
        let silence = MockSilenceDetectionService()
        if !heardSpeech { silence.noSpeechWindowVerdict = .possibleSpeech }
        let model = await guestAtTypedQuestion(silence: silence)
        defer { model.stopAll() }
        await model.toggleRecording()
        if heardSpeech { silence.simulateSilenceEvent(.speechStarted) }
        silence.simulateAnswerAudio(Data(count: 32000))
        await settle()
        await clock.advance(by: .seconds(Config.speechStartWindow + 1))
        await settle()
        #expect(model.voicePhase == .recording)

        await clock.advance(by: .seconds(15))
        await settle()
        #expect(rooms.voiceUploads.count == 1, "the time running out sends the recording")
    }

    // MARK: - One recording, one answer

    @Test("Stop sends the recording once and the server's transcript locks the answer")
    func recordAndSend() async {
        let model = await guestAtTypedQuestion()
        defer { model.stopAll() }
        await speak(model)
        #expect(model.listenPhase == .listening(.open))

        await model.toggleRecording()
        #expect(rooms.voiceUploads.count == 1)
        #expect(model.round?.yourAnswer == "Canberra")
        #expect(model.voicePhase == .idle && !audio.isRecording)
        // A second tap after the answer locked sends nothing.
        await model.toggleRecording()
        #expect(rooms.voiceUploads.count == 1)
        #expect(typedQuestionAnswers == ["Canberra"])
    }

    // WHY: solo stops and sends when the time runs out mid-answer; the
    // server counts a recording that arrives within its grace.
    @Test("the time running out while recording sends what was recorded, not the typed draft")
    func timeoutWhileRecording() async {
        let model = await guestAtTypedQuestion()
        defer { model.stopAll() }
        model.typedAnswer = "Sydney"
        await speak(model)

        await clock.advance(by: .milliseconds(19900))
        await settle()
        #expect(rooms.voiceUploads.isEmpty, "sent before the time ran out")
        await clock.advance(by: .milliseconds(200))
        await pumpUntil { rooms.voiceUploads.count == 1 }
        await settle()
        #expect(typedQuestionAnswers == ["Canberra"], "the typed draft went in next to the recording")
        #expect(!audio.isRecording)
    }

    @Test("a recording still uploading at zero is not joined by the typed draft")
    func uploadInFlightAtTimeout() async {
        let model = await guestAtTypedQuestion()
        defer { model.stopAll() }
        model.typedAnswer = "Sydney"
        let hold = rooms.conditions.hold(.answerByVoice)
        await speak(model)
        let stop = Task { await model.toggleRecording() }
        await pumpUntil { hold.heldCount == 1 }
        #expect(model.listenPhase == .evaluating, "a slow upload must show progress")
        #expect(!model.canAnswer)

        await clock.advance(by: .seconds(21))
        await settle()
        #expect(rooms.answers.count == 1, "the timeout sent the draft while the recording was on its way")
        hold.release()
        await stop.value
        #expect(typedQuestionAnswers == ["Canberra"])
    }

    // MARK: - Nothing heard

    // WHY: like solo, silence is no answer: "Didn't catch that", nothing is
    // stored, and with time left the player can say it again.
    @Test("the server hearing nothing stores nothing and the player may answer again")
    func nothingHeard() async {
        let model = await guestAtTypedQuestion()
        defer { model.stopAll() }
        rooms.voiceTranscript = nil
        await speak(model)
        await model.toggleRecording()
        #expect(model.voiceNote == .didNotCatch)
        #expect(model.round?.yourAnswer == nil && model.canSpeak)

        rooms.voiceTranscript = "Canberra"
        await speak(model)
        await model.toggleRecording()
        #expect(model.round?.yourAnswer == "Canberra")
        #expect(model.voiceNote == nil)
    }

    @Test("a tap on Stop with no audio never reaches the server")
    func silenceNotUploaded() async {
        let model = await guestAtTypedQuestion()
        defer { model.stopAll() }
        await model.toggleRecording()
        await model.toggleRecording()
        #expect(rooms.voiceUploads.isEmpty)
        #expect(model.voiceNote == .didNotCatch && model.canSpeak)
    }

    // MARK: - Bad network

    @Test("a failed upload leaves a clear note, typing works and the game goes on", arguments: [
        NetworkCondition.serverError(statusCode: 502), .offline, .malformed, .timeout,
    ])
    func failedUpload(condition: NetworkCondition) async {
        let model = await guestAtTypedQuestion()
        defer { model.stopAll() }
        rooms.conditions.setNetworkCondition(condition, for: [.answerByVoice])
        await speak(model)
        let stop = Task { await model.toggleRecording() }
        // A timeout only fires once the clock passes the request's limit.
        await settle()
        await clock.advance(by: .seconds(31))
        await stop.value

        #expect(model.voicePhase == .idle, "the Answer button spins forever")
        #expect(model.voiceNote == .notSent)
        #expect(model.errorMessage == nil, "a blocking error replaced the question")
        #expect(model.screen == .question)
        rooms.othersAnswer()
        await model.refresh()
        #expect(model.screen == .reveal, "the player cannot continue after a failed upload")
    }

    @Test("after a failed upload the player can still type the answer")
    func typeAfterFailedUpload() async {
        let model = await guestAtTypedQuestion()
        defer { model.stopAll() }
        rooms.conditions.setNetworkCondition(.offline, for: [.answerByVoice])
        await speak(model)
        await model.toggleRecording()
        #expect(model.canAnswer)
        model.typedAnswer = "Canberra"
        await model.submitTypedAnswer()
        #expect(typedQuestionAnswers == ["Canberra"])
    }

    // MARK: - Microphone refused

    // WHY: a refused mic must never leave a dead button: typing works and
    // the bar says the microphone is off (solo's note with Settings).
    @Test("a refused microphone records nothing and the typed answer still goes in")
    func micRefused() async throws {
        let model = await guestAtTypedQuestion()
        defer { model.stopAll() }
        audio.micPermissionResult = false
        await model.toggleRecording()
        #expect(model.voicePhase == .idle && !audio.isRecording)
        #expect(model.micDenied)
        let view = try RoomQuestionView(viewModel: model).inspect()
        let answer = try view.find(viewWithAccessibilityIdentifier: "room.answer.record").button()
        #expect(!answer.isDisabled(), "Answer must open typing, not sit dead")

        model.typedAnswer = "Canberra"
        await model.submitTypedAnswer()
        #expect(typedQuestionAnswers == ["Canberra"])
        #expect(rooms.voiceUploads.isEmpty)
    }

    // MARK: - Leaving

    @Test("closing the game mid-recording sends nothing")
    func leaveWhileRecording() async {
        let model = await guestAtTypedQuestion()
        await speak(model)
        await model.leave()
        #expect(!audio.isRecording)
        #expect(rooms.voiceUploads.isEmpty)
    }
}
