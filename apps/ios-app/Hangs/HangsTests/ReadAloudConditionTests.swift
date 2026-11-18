//
//  ReadAloudConditionTests.swift
//  HangsTests
//
//  #235.2 (flow × condition, read-aloud row). The app reads the question, the
//  result and short spoken lines from audio the server sends. On a bad network
//  that audio arrives late or never. The rule: a late clip never speaks over
//  something the player already moved on to, and a clip that never comes
//  never holds a screen silent without its buttons and commands.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@Suite("Read-aloud on a bad network (#235.2)")
@MainActor
struct ReadAloudConditionTests {
    private struct Rig {
        let vm: QuizViewModel
        let network: MockNetworkService
        let audio: MockAudioService
        let silence: MockSilenceDetectionService
        let clock: TestClock<Duration>
    }

    private func makeRig(state: QuizState = .askingQuestion) -> Rig {
        let clock = TestClock()
        let network = Fixtures.makeFullMockNetwork()
        network.networkClock = AnyClock(clock)
        network.mockAudioData = Data("opus-bytes".utf8)
        let audio = MockAudioService()
        audio.playbackDurationNs = 0
        let silence = MockSilenceDetectionService()
        let vm = QuizViewModel(
            networkService: network,
            audioService: audio,
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: silence,
            clock: AnyClock(clock)
        )
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        vm.quizState = state
        return Rig(vm: vm, network: network, audio: audio, silence: silence, clock: clock)
    }

    /// Starts the question read with its audio download held at the server.
    private func startHeldRead(_ rig: Rig) async -> (Task<Void, Never>, NetworkHold) {
        let hold = rig.network.hold(.downloadAudio)
        let read = Task { await rig.vm.audioDeviceState.playQuestionAudio(from: "https://example.com/q.mp3") }
        await pumpUntil({ hold.heldCount == 1 }, "the question audio never reached the server")
        #expect(rig.vm.isPlayingQuestionTTS, "the screen must show the question is being read")
        return (read, hold)
    }

    // MARK: - Question audio that arrives late

    // WHY: on a slow network the driver taps to answer before the question
    // audio has even arrived. The tap stops the read; audio that lands after
    // it must not start reading the question into the open microphone, which
    // records the app's own voice as the answer.
    @Test("question audio that arrives after the player tapped to answer is never played over the recording")
    func lateQuestionAudioAfterTapStaysSilent() async {
        let rig = makeRig()
        let (read, hold) = await startHeldRead(rig)

        await rig.vm.toggleRecording()
        #expect(rig.vm.quizState == .recording)
        hold.release()
        await read.value

        #expect(rig.audio.playOpusCallCount == 0, "the question was read over the player's answer")
        #expect(rig.vm.quizState == .recording)
    }

    // WHY: mute means silence now (founder TF 2026-09-14). A clip still
    // downloading when the player mutes must not start speaking afterwards.
    @Test("question audio that arrives after the player muted stays silent")
    func lateQuestionAudioAfterMuteStaysSilent() async {
        let rig = makeRig()
        let (read, hold) = await startHeldRead(rig)

        await rig.vm.toggleMute()
        hold.release()
        await read.value

        #expect(rig.audio.playOpusCallCount == 0, "a muted quiz spoke the question")
        #expect(rig.vm.quizState == .askingQuestion)
    }

    // WHY: tapping an option answers the question. A question read that lands
    // during the evaluation or on the result would talk over the verdict.
    @Test("question audio that arrives after an option was tapped is never played")
    func lateQuestionAudioAfterOptionTapStaysSilent() async {
        let rig = makeRig()
        let (read, hold) = await startHeldRead(rig)

        await rig.vm.submitMCQAnswer(key: "a", value: "Paris")
        #expect(rig.vm.quizState.isShowingResult)
        hold.release()
        await read.value

        #expect(rig.audio.playOpusCallCount == 0, "the question was read over the result")
    }

    // MARK: - Spoken lines (#188 G1, G3, G4)

    // WHY: the error line comes from the server's speech service, often on the
    // same bad network that caused the error. It may cost at most its 3 s
    // bound; then the error screen listens for "again" / "stop" without it.
    // Pins today's silent fallback (a founder decision, see the issue file).
    @Test("an error line that never arrives costs 3 s, then the error screen listens without it")
    func errorLineTimeoutFallsBackToListening() async {
        let rig = makeRig(state: .processing)
        rig.network.setNetworkCondition(.timeout, for: [.synthesizeSpeech])

        rig.vm.setError(message: "offline", context: .submission, error: URLError(.notConnectedToInternet))
        await pumpUntil { rig.network.synthesizedTexts.count == 1 }
        await rig.clock.advance(by: .milliseconds(2999))
        #expect(!rig.vm.quizEndCommandsArmed, "the screen gave up on the line before its bound")
        await rig.clock.advance(by: .milliseconds(1))

        await pumpUntil({ rig.vm.quizEndCommandsArmed }, "the error screen never started listening")
        #expect(rig.audio.playOpusCallCount == 0)
        #expect(rig.vm.quizState.isError)
    }

    // WHY: a line that fails at once must not hold anything up either.
    @Test("an error line that fails at once leaves the error screen listening", arguments: [
        NetworkCondition.offline, .serverError(statusCode: 500), .malformed,
    ])
    func errorLineFailureFallsBackToListening(condition: NetworkCondition) async {
        let rig = makeRig(state: .processing)
        rig.network.setNetworkCondition(condition, for: [.synthesizeSpeech])

        rig.vm.setError(message: "offline", context: .submission, error: URLError(.notConnectedToInternet))

        await pumpUntil({ rig.vm.quizEndCommandsArmed }, "the error screen never started listening")
        #expect(rig.audio.playOpusCallCount == 0)
    }

    // WHY: the score line is fetched after the set ends. If the player is
    // already back Home when it arrives, it must not speak (or open a
    // listener) on a screen that has nothing to do with it.
    @Test("a score line that arrives after the player went Home is never spoken")
    func lateScoreLineAfterHomeStaysSilent() async {
        let rig = makeRig(state: .processing)
        let hold = rig.network.hold(.synthesizeSpeech)
        await rig.vm.handleError(NetworkError.sessionFinished, context: .submission, fallbackMessage: "x")
        #expect(rig.vm.quizState == .finished)
        await pumpUntil({ hold.arrivals == 1 }, "the score line was never asked for")

        rig.vm.resetToHome()
        hold.release()
        for _ in 0 ..< 50 {
            await Task.yield()
        }

        #expect(rig.audio.playOpusCallCount == 0, "the score line spoke on Home")
        #expect(!rig.vm.quizEndCommandsArmed)
        #expect(rig.vm.quizState == .idle)
    }

    // WHY: "hear it" on the result is a tap. When the speech service fails the
    // screen must say it cannot be read right now (founder 2026-11-17, F3),
    // and still give the result screen its voice commands back.
    @Test("a 'hear it' read that cannot be fetched says so and gives the result screen its listener back")
    func failedExplanationReadSaysSo() async {
        let rig = makeRig()
        rig.network.setNetworkCondition(.offline, for: [.synthesizeSpeech])
        rig.vm.quizState = Self.result

        rig.vm.readExplanationAloud("Venus is hotter because of its thick atmosphere.")

        await pumpUntil({ rig.silence.isListening }, "the result screen lost its listener")
        #expect(rig.audio.playOpusCallCount == 0)
        #expect(rig.vm.readAloudFailure == .explanation, "the failed read stayed silent")
        #expect(rig.vm.quizState.isShowingResult)
    }

    // WHY: the note is about the last try only. A tap that plays removes it,
    // and so does leaving the result screen.
    @Test("the 'can't be read' note goes with the next read that plays and with the screen")
    func failureNoteClears() async {
        let rig = makeRig()
        rig.network.setNetworkCondition(.offline, for: [.synthesizeSpeech])
        rig.vm.quizState = Self.result
        rig.vm.readExplanationAloud("Venus.")
        await pumpUntil { rig.vm.readAloudFailure == .explanation }

        rig.network.setNetworkCondition(nil, for: [.synthesizeSpeech])
        rig.vm.readExplanationAloud("Venus.")
        await pumpUntil({ rig.vm.readAloudFailure == nil }, "a read that played kept the note")
        #expect(rig.audio.playOpusCallCount == 1)

        rig.network.setNetworkCondition(.offline, for: [.synthesizeSpeech])
        rig.vm.readExplanationAloud("Venus.")
        await pumpUntil { rig.vm.readAloudFailure == .explanation }
        rig.vm.quizState = .askingQuestion
        #expect(rig.vm.readAloudFailure == nil, "the note followed the player to the next question")
    }

    // WHY: the recap's own "hear it" (a row, or the whole summary) fails the
    // same way and must say so next to the button that asked.
    @Test("a recap read that cannot be fetched says so next to its button")
    func failedRecapReadSaysSo() async {
        let rig = makeRig(state: .finished)
        rig.network.setNetworkCondition(.serverError(statusCode: 500), for: [.synthesizeSpeech])
        let entry = RecapEntry(
            number: 3,
            question: Fixtures.makeQuestion(id: "q_003"),
            evaluation: Evaluation(userAnswer: "b", result: .incorrect, points: 0, correctAnswer: "a", questionId: "q_003", explanation: "Because.")
        )

        rig.vm.playRecapEntryExplanation(entry)

        await pumpUntil({ rig.vm.readAloudFailure == .recapEntry(3) }, "the failed recap read stayed silent")
        #expect(rig.audio.playOpusCallCount == 0)
    }

    private static let result = QuizState.showingResult(
        question: Fixtures.makeQuestion(id: "q_001"),
        evaluation: Evaluation(userAnswer: "b", result: .incorrect, points: 0, correctAnswer: "a", questionId: "q_001", explanation: nil)
    )

    // WHY: the spoken verdict decides how long the result stays up before the
    // next question. A verdict clip that cannot be downloaded must still hand
    // back a duration and reopen the listener, or auto-advance would stall.
    @Test("a verdict clip that cannot be downloaded falls back to a short pause and reopens the listener", arguments: [
        NetworkCondition.offline, .serverError(statusCode: 500), .malformed,
    ])
    func failedVerdictClipFallsBack(condition: NetworkCondition) async {
        let rig = makeRig()
        rig.network.setNetworkCondition(condition, for: [.downloadAudio])

        let duration = await rig.vm.audioDeviceState.playFeedbackAudio(from: "https://example.com/verdict.mp3")

        #expect(duration == 3.0)
        #expect(rig.audio.playOpusCallCount == 0)
        #expect(!rig.vm.isPlayingFeedbackTTS)
        #expect(rig.silence.isListening)
    }
}
