//
//  ConfirmationSheetVoiceTests.swift
//  HangsTests
//
//  #185 track D — the answer confirmation sheet listens (car test 2026-09-23,
//  founder decisions of 2026-09-24):
//   5.1 (reversed by #243.5, founder 2026-11-24) anything said on the sheet
//       was a new answer; now the sheet listens for "again" only and any
//       other speech changes nothing;
//   5.2 the countdown starts only once the command listener is live;
//   5.3 (retired 2026-11-22) the "stop" hold and the spoken confirm are gone;
//   plus the no-answer sheet (track B), where "potvrď" used to skip.
//  Time is a `TestClock`; the recognizer and the upload are mocks.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

/// One-shot async gate — holds a mocked call in flight deterministically.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

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

@Suite("#185 the confirmation sheet listens (5.2; #243.5 only \"again\")")
@MainActor
struct ConfirmationSheetVoiceTests {
    private func makeVM(clock: TestClock<Duration>) -> (QuizViewModel, MockSilenceDetectionService, MockNetworkService) {
        let silence = MockSilenceDetectionService()
        let audio = MockAudioService()
        audio.playbackDurationNs = 0
        let network = Fixtures.makeFullMockNetwork()
        let vm = QuizViewModel(
            networkService: network,
            audioService: audio,
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: silence,
            clock: AnyClock(clock)
        )
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        vm.recordingCoordinator.speechStartWindow = 60
        vm.recordingCoordinator.deadAirCap = 60
        return (vm, silence, network)
    }

    /// The sheet for a recorded "Paris", read back, listener live, counting down.
    private func openSheet(_ vm: QuizViewModel, _ silence: MockSilenceDetectionService, answer: String = "Paris") async {
        vm.quizState = .processing
        vm.recordingCoordinator.pendingResponse = response(answer: answer)
        vm.recordingCoordinator.presentVoiceTranscript(answer)
        await pumpUntil({ vm.autoConfirmCountdown == Config.autoConfirmDelaySecs }, "the countdown never started")
        #expect(silence.isListening, "the sheet listens for \"again\"")
    }

    // MARK: - 5.2

    /// WHY (car test): the 5 s countdown started with the listener restart, which
    /// took up to 3 s — "znova" had no time. The countdown must wait for the mic.
    @Test("5.2: no countdown until the command listener is live")
    func countdownWaitsForLiveListener() async {
        let (vm, silence, _) = makeVM(clock: TestClock())
        let gate = Gate()
        silence.onStartListeningSuspend = { await gate.wait() }
        vm.quizState = .processing
        vm.recordingCoordinator.pendingResponse = response(answer: "Paris")

        vm.recordingCoordinator.presentVoiceTranscript("Paris")
        await pumpUntil({ silence.startListeningCallCount >= 1 }, "the listener was never asked to start")
        await drain()
        #expect(vm.autoConfirmCountdown == 0, "the countdown ran on a deaf mic")
        #expect(vm.isAutoConfirmHeld, "a held countdown is waiting, not run out (Again stays tappable)")

        await gate.open()
        await pumpUntil({ vm.autoConfirmCountdown == Config.autoConfirmDelaySecs }, "live listener never started the countdown")
        #expect(vm.isAutoConfirmHeld == false)
    }

    /// WHY: with voice commands OFF no listener is coming — waiting for one
    /// would leave the sheet without its auto-confirm for good.
    @Test("5.2: commands off → the countdown starts without a listener")
    func noListenerNoWait() async {
        let (vm, silence, _) = makeVM(clock: TestClock())
        vm.settings.voiceCommandsEnabled = false
        vm.quizState = .processing
        vm.recordingCoordinator.pendingResponse = response(answer: "Paris")

        vm.recordingCoordinator.presentVoiceTranscript("Paris")
        await pumpUntil({ vm.autoConfirmCountdown == Config.autoConfirmDelaySecs }, "no countdown without commands")
        #expect(silence.isAnswerCaptureActive == false, "no mic, nothing to keep")
    }

    // MARK: - #243.5: only "again"

    /// WHY (#243.5, founder 2026-11-24, reverses #185 5.1): the sheet listens
    /// for "again" only. Anything else said over it — a correction, a passenger,
    /// the radio — changes nothing: no upload, the answer stands, and the
    /// countdown that speech held resumes with a full window.
    @Test("#243.5: a spoken non-command changes nothing on the sheet")
    func nonCommandChangesNothing() async {
        let clock = TestClock()
        let (vm, silence, network) = makeVM(clock: clock)
        await openSheet(vm, silence)
        let attempt = vm.currentAttempt

        silence.simulateAnswerAudio(Data(count: 16000))
        silence.simulateCommandTranscript("carling", isFinal: false)
        await pumpUntil({ vm.recordingCoordinator.countdownHold == .speech }, "speech did not hold the countdown")
        silence.simulateCommandTranscript("carling")
        await pumpUntil({ vm.autoConfirmCountdown == Config.autoConfirmDelaySecs }, "the countdown stayed held")

        #expect(network.submitVoiceAnswerCallCount == 0, "the speech was uploaded as a new answer")
        #expect(vm.transcribedAnswer == "Paris")
        #expect(vm.currentAttempt == attempt, "a new answer attempt was opened")
        #expect(vm.quizState == .processing && vm.showAnswerConfirmation)
    }

    /// WHY (founder 2026-11-22): "stop" and "confirm" are no commands any
    /// more; with #243.5 they are not an answer either — just ignored.
    @Test("'stop' and 'confirm' on the sheet change nothing", arguments: ["stop", "confirm"])
    func removedWordsChangeNothing(_ spoken: String) async {
        let (vm, silence, network) = makeVM(clock: TestClock())
        await openSheet(vm, silence)

        silence.simulateAnswerAudio(Data(count: 16000))
        silence.simulateCommandTranscript(spoken)
        await drain()
        #expect(network.submitVoiceAnswerCallCount == 0)
        #expect(network.submitTextInputCallCount == 0, "'\(spoken)' confirmed the answer")
        #expect(vm.transcribedAnswer == "Paris")
        #expect(vm.quizState == .processing)
    }

    /// WHY: "again" is the sheet's one word — it records the answer again.
    @Test("#243.5: 'again' on the sheet records again")
    func againReRecords() async {
        let (vm, silence, _) = makeVM(clock: TestClock())
        await openSheet(vm, silence)
        silence.simulateCommandTranscript("again")
        await pumpUntil({ vm.quizState == .recording }, "'again' did not re-record")
        #expect(vm.showAnswerConfirmation == false)
    }

    /// WHY: silence still confirms — the countdown runs out and the answer is
    /// graded with no word from the player.
    @Test("#243.5: silence on the sheet auto-confirms")
    func silenceAutoConfirms() async {
        let clock = TestClock()
        let (vm, silence, _) = makeVM(clock: clock)
        await openSheet(vm, silence)
        await clock.advance(by: .seconds(Config.autoConfirmDelaySecs + 1))
        await pumpUntil({ vm.quizState.isShowingResult }, "the countdown never confirmed")
        #expect(vm.resultEvaluation?.userAnswer == "Paris")
    }

    /// WHY: filler or a blip — a held countdown resumes with a full window.
    @Test("speech that ends in nothing resumes the countdown")
    func noiseResumes() async {
        let (vm, silence, network) = makeVM(clock: TestClock())
        await openSheet(vm, silence)

        silence.simulateCommandTranscript("carling", isFinal: false)
        await pumpUntil({ vm.recordingCoordinator.countdownHold == .speech })
        silence.simulateCommandTranscript("hmm")
        await pumpUntil({ vm.autoConfirmCountdown == Config.autoConfirmDelaySecs }, "the countdown stayed held")
        #expect(network.submitVoiceAnswerCallCount == 0)
        #expect(vm.transcribedAnswer == "Paris")
    }

    /// WHY (founder 2026-11-22): with the confirm command gone, "ok" / "yeah"
    /// said over the sheet are the driver's filler — the old answer stays.
    @Test("'ok' / 'yeah' on the sheet are noise, the old answer stays", arguments: ["ok", "yeah"])
    func fillerIsNoise(_ spoken: String) async {
        let (vm, silence, network) = makeVM(clock: TestClock())
        await openSheet(vm, silence)

        silence.simulateCommandTranscript("carling", isFinal: false)
        await pumpUntil({ vm.recordingCoordinator.countdownHold == .speech })
        silence.simulateCommandTranscript(spoken)
        await pumpUntil({ vm.autoConfirmCountdown == Config.autoConfirmDelaySecs }, "the countdown stayed held")
        #expect(network.submitVoiceAnswerCallCount == 0)
        #expect(vm.transcribedAnswer == "Paris")
    }

    /// WHY: a recognizer that never finalizes must not freeze the sheet.
    @Test("speech holds the countdown for a bounded time only")
    func speechHoldIsBounded() async {
        let clock = TestClock()
        let (vm, silence, _) = makeVM(clock: clock)
        await openSheet(vm, silence)

        silence.simulateCommandTranscript("carling", isFinal: false)
        await pumpUntil({ vm.recordingCoordinator.countdownHold == .speech })
        await clock.advance(by: .seconds(RecordingCoordinator.speechHoldLimitSeconds - 1))
        await drain()
        #expect(vm.autoConfirmCountdown == 0)
        await clock.advance(by: .seconds(1))
        await pumpUntil({ vm.autoConfirmCountdown == Config.autoConfirmDelaySecs }, "the hold never ran out")
    }

    /// WHY (#231 — Ukrainian as a fourth language, PR #862 review): «Правильно»
    /// is how a Ukrainian says "right", «Неправда» how the app asks a false
    /// statement to be answered. Both sit one letter from «неправильно»
    /// ("wrong" = record again) and re-recorded the answer. They must not
    /// count as "again" — and (#243.5) they change nothing.
    @Test("uk: «Правильно» / «Неправда» on the sheet are not 'again'", arguments: ["Правильно.", "Неправда."])
    func ukrainianNearWrongIsNotAgain(_ spoken: String) async {
        let (vm, silence, network) = makeVM(clock: TestClock())
        vm.settings.language = "uk"
        vm.currentSession = Fixtures.makeActiveSession(language: "uk")
        await openSheet(vm, silence, answer: "Київ")

        silence.simulateAnswerAudio(Data(count: 16000))
        silence.simulateCommandTranscript(spoken)
        await drain()
        #expect(vm.quizState == .processing, "'\(spoken)' re-recorded the answer")
        #expect(vm.transcribedAnswer == "Київ")
        #expect(network.submitVoiceAnswerCallCount == 0)
    }

    // MARK: - The no-answer sheet

    /// WHY (car test): "potvrď" on the Again/Skip sheet SKIPPED the question.
    /// Skipping must be asked for ("next"), and the hint names that sheet's
    /// own words (#243.4: repeat, again, next — after the spoken offer).
    @Test("no-answer sheet: 'confirm' does nothing, 'next' skips, the hint names repeat/again/next")
    func noAnswerSheet() async {
        let clock = TestClock()
        let (vm, silence, network) = makeVM(clock: clock)
        vm.quizState = .processing
        vm.recordingCoordinator.handleTranscriptionFailure(allowAutoRetry: false)
        await pumpUntil({ !vm.recordingCoordinator.isSpeakingRetryPrompt }, "the offer line never ended")
        await vm.audioDeviceState.startSilenceDetectionListening()
        #expect(vm.voiceCommandCoordinator.currentCommandScreen == .noAnswer)
        #expect(vm.commandListenerHint == VoiceCommandLexicon.hint(on: .noAnswer, language: .english))

        silence.simulateCommandTranscript("confirm")
        await drain()
        #expect(network.submitTextInputCallCount == 0, "a confirm skipped the question")
        #expect(vm.showAnswerConfirmation)

        silence.simulateCommandTranscript("next")
        await pumpUntil({ network.submitTextInputCallCount == 1 }, "'next' did not skip")
    }

    /// WHY (PR #199 review): pausing takes the mic down; resuming on the
    /// Again/Skip sheet must bring its "znova" / "ďalšia" listener back even
    /// though that sheet has no countdown to re-arm — otherwise the driver is
    /// left with a tap as the only way off it.
    @Test("resuming a paused no-answer sheet re-arms its command listener")
    func resumeNoAnswerSheetReArmsListener() async {
        let (vm, silence, network) = makeVM(clock: TestClock())
        vm.quizState = .processing
        vm.recordingCoordinator.handleTranscriptionFailure(allowAutoRetry: false)
        await pumpUntil({ !vm.recordingCoordinator.isSpeakingRetryPrompt }, "the offer line never ended")
        await vm.audioDeviceState.startSilenceDetectionListening()
        vm.enterPause()
        await pumpUntil({ vm.voiceCommandCoordinator.commandCapturePhase == .idle }, "pause kept the mic up")

        vm.exitPause()
        await pumpUntil({ vm.voiceCommandCoordinator.commandCapturePhase == .listening }, "resume never re-armed the listener")
        #expect(vm.voiceCommandCoordinator.currentCommandScreen == .noAnswer)
        #expect(vm.autoConfirmCountdown == 0, "the no-answer sheet still never counts down")

        silence.simulateCommandTranscript("next")
        await pumpUntil({ network.submitTextInputCallCount == 1 }, "'next' after resume did nothing")
    }
}
