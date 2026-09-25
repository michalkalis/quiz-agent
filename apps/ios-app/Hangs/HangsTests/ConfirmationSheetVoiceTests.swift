//
//  ConfirmationSheetVoiceTests.swift
//  HangsTests
//
//  #185 track D — the answer confirmation sheet listens (car test 2026-09-23,
//  founder decisions 5.1–5.3 of 2026-09-24):
//   5.1 anything said on the sheet that is not a command is a new answer;
//   5.2 the countdown starts only once the command listener is live;
//   5.3 "stop" only holds the countdown — the sheet then waits;
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

@Suite("#185 the confirmation sheet listens (5.1–5.3)")
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
            sttService: nil,
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
        #expect(silence.isAnswerCaptureActive, "the live sheet keeps the listener's audio")
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

    // MARK: - 5.3

    /// WHY (founder): "stop" only stops the automatic advance; the sheet waits,
    /// still listening, for a command or a tap. It used to CANCEL the answer.
    @Test("5.3: 'stop' holds the countdown, keeps listening, and 'confirm' still works")
    func stopHoldsAndWaits() async {
        let clock = TestClock()
        let (vm, silence, network) = makeVM(clock: clock)
        await openSheet(vm, silence)

        silence.simulateCommandTranscript("stop")
        await pumpUntil({ vm.recordingCoordinator.countdownHold == .driverStop }, "'stop' did not hold")
        await clock.advance(by: .seconds(Config.autoConfirmDelaySecs * 3))
        await drain()
        #expect(vm.showAnswerConfirmation, "the sheet waited")
        #expect(vm.quizState == .processing, "'stop' no longer cancels the answer")
        #expect(vm.transcribedAnswer == "Paris")
        #expect(vm.autoConfirmCountdown == 0)
        #expect(vm.voiceCommandCoordinator.commandCapturePhase == .listening, "the sheet still listens")

        silence.simulateCommandTranscript("confirm")
        await pumpUntil({ vm.quizState.isShowingResult }, "'confirm' after 'stop' did nothing")
        #expect(network.submitVoiceAnswerCallCount == 0, "the recorded grade was used")
    }

    // MARK: - 5.1

    /// WHY (founder 5.1): the driver simply says the answer again. Speech holds
    /// the countdown (it must not confirm "Paris" under "Curling"), the words
    /// are transcribed from the audio like any answer, and the new answer
    /// replaces the old one on the sheet — read back, countdown re-armed.
    @Test("5.1: a spoken non-command on the sheet becomes the new answer")
    func spokenAnswerReplaces() async {
        let clock = TestClock()
        let (vm, silence, network) = makeVM(clock: clock)
        await openSheet(vm, silence)
        let oldAttempt = vm.currentAttempt
        network.mockResponse = response(answer: "Curling")

        silence.simulateAnswerAudio(Data(count: 16000))
        silence.simulateCommandTranscript("carling", isFinal: false)
        await pumpUntil({ vm.recordingCoordinator.countdownHold == .speech }, "speech did not hold the countdown")
        #expect(vm.autoConfirmCountdown == 0)
        await clock.advance(by: .seconds(Config.autoConfirmDelaySecs + 1))
        await drain()
        #expect(vm.showAnswerConfirmation, "the old answer was confirmed under the new one")

        silence.simulateCommandTranscript("carling")
        await pumpUntil({ vm.transcribedAnswer == "Curling" }, "the new answer never replaced the old one")
        #expect(network.submitVoiceAnswerCallCount == 1)
        #expect(network.capturedVoiceAnswerFileName == "answer.wav")
        #expect((network.capturedVoiceAnswerBytes ?? 0) > 16000, "the sheet's audio was uploaded, not the recognizer's text")
        #expect(vm.currentAttempt != oldAttempt, "a new answer is a new attempt")
        // The read-back is its own task: wait for it rather than assume it ran.
        await pumpUntil({ network.synthesizedTexts.last == "Curling" }, "the new answer is not read back")
        await pumpUntil({ vm.autoConfirmCountdown == Config.autoConfirmDelaySecs }, "no countdown for the new answer")
        #expect(vm.attemptLedger.invariantViolations.isEmpty)
    }

    /// WHY: filler or a blip is not an answer — a held countdown resumes with a
    /// full window, and nothing is uploaded.
    @Test("5.1: speech that ends in nothing resumes the countdown")
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

    /// WHY: a recognizer that never finalizes must not freeze the sheet.
    @Test("5.1: speech holds the countdown for a bounded time only")
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

    /// WHY: the on-device recognizer misses commands in the cabin — that is the
    /// whole car-test problem. If the upload turns out to be "Confirm.", it was
    /// a confirm of the OLD answer, never the answer "Confirm". The old grade is
    /// stale (the backend graded the newer audio last), so the text is re-graded.
    @Test("5.1: a command word heard only by the answer transcription confirms the old answer")
    func transcribedCommandConfirmsOldAnswer() async {
        let (vm, silence, network) = makeVM(clock: TestClock())
        await openSheet(vm, silence)
        network.mockResponse = response(answer: "Confirm.")

        silence.simulateAnswerAudio(Data(count: 16000))
        silence.simulateCommandTranscript("the firm")
        await pumpUntil({ network.submitTextInputCallCount == 1 }, "the old answer was not confirmed")
        #expect(network.capturedTextInputInput == "Paris")
        #expect(vm.transcribedAnswer != "Confirm.")
    }

    /// WHY: cabin noise the recognizer took for words must not destroy a good
    /// answer — an empty transcription keeps the old one, with no retry prompt.
    @Test("5.1: an unheard new answer keeps the old one")
    func unheardKeepsOld() async {
        let (vm, silence, network) = makeVM(clock: TestClock())
        await openSheet(vm, silence)
        network.submitVoiceAnswerError = NetworkError.serverError(statusCode: 400, message: "speech not understood")
        let promptsBefore = network.synthesizedTexts.count

        silence.simulateAnswerAudio(Data(count: 16000))
        silence.simulateCommandTranscript("carling")
        await pumpUntil({ network.submitVoiceAnswerCallCount == 1 })
        await pumpUntil({ vm.transcribedAnswer == "Paris" && vm.recordingCoordinator.spokenReplacement == nil },
                        "the old answer did not come back")
        #expect(vm.showAnswerConfirmation)
        #expect(vm.quizState == .processing, "no retry recording")
        #expect(!network.synthesizedTexts.dropFirst(promptsBefore).contains(SpokenPrompt.didNotCatch.text(language: .english)))
    }

    /// WHY (#186 ticket): a re-record while the new answer uploads owns the
    /// question — the late transcript must not reopen the sheet over it.
    @Test("5.1: 'again' during the upload wins; the late transcript is dropped")
    func againDuringUploadWins() async {
        let (vm, silence, network) = makeVM(clock: TestClock())
        await openSheet(vm, silence)
        let gate = Gate()
        network.submitVoiceAnswerGate = { await gate.wait() }
        network.mockResponse = response(answer: "Curling")

        silence.simulateAnswerAudio(Data(count: 16000))
        silence.simulateCommandTranscript("carling")
        await pumpUntil({ network.submitVoiceAnswerCallCount == 1 })
        silence.simulateCommandTranscript("again")
        await pumpUntil({ vm.quizState == .recording }, "'again' did not re-record")

        await gate.open()
        await drain()
        #expect(vm.showAnswerConfirmation == false)
        #expect(vm.transcribedAnswer != "Curling")
        #expect(vm.quizState == .recording)
    }

    // MARK: - The no-answer sheet

    /// WHY (car test): "potvrď" on the Again/Skip sheet SKIPPED the question.
    /// Skipping must be asked for ("preskoč"), and the hint names that sheet's
    /// own words.
    @Test("no-answer sheet: 'confirm' does nothing, 'skip' skips, the hint names again/skip")
    func noAnswerSheet() async {
        let clock = TestClock()
        let (vm, silence, network) = makeVM(clock: clock)
        vm.quizState = .processing
        vm.recordingCoordinator.handleTranscriptionFailure(allowAutoRetry: false)
        await vm.audioDeviceState.startSilenceDetectionListening()
        #expect(vm.voiceCommandCoordinator.currentCommandScreen == .noAnswer)
        #expect(vm.commandListenerHint == VoiceCommandLexicon.hint(on: .noAnswer, language: .english))

        silence.simulateCommandTranscript("confirm")
        await drain()
        #expect(network.submitTextInputCallCount == 0, "a confirm skipped the question")
        #expect(vm.showAnswerConfirmation)

        silence.simulateCommandTranscript("skip")
        await pumpUntil({ network.submitTextInputCallCount == 1 }, "'skip' did not skip")
    }

    /// WHY (PR #199 review): pausing takes the mic down; resuming on the
    /// Again/Skip sheet must bring its "znova" / "preskoč" listener back even
    /// though that sheet has no countdown to re-arm — otherwise the driver is
    /// left with a tap as the only way off it.
    @Test("resuming a paused no-answer sheet re-arms its command listener")
    func resumeNoAnswerSheetReArmsListener() async {
        let (vm, silence, network) = makeVM(clock: TestClock())
        vm.quizState = .processing
        vm.recordingCoordinator.handleTranscriptionFailure(allowAutoRetry: false)
        await vm.audioDeviceState.startSilenceDetectionListening()
        vm.enterPause()
        await pumpUntil({ vm.voiceCommandCoordinator.commandCapturePhase == .idle }, "pause kept the mic up")

        vm.exitPause()
        await pumpUntil({ vm.voiceCommandCoordinator.commandCapturePhase == .listening }, "resume never re-armed the listener")
        #expect(vm.voiceCommandCoordinator.currentCommandScreen == .noAnswer)
        #expect(vm.autoConfirmCountdown == 0, "the no-answer sheet still never counts down")

        silence.simulateCommandTranscript("skip")
        await pumpUntil({ network.submitTextInputCallCount == 1 }, "'skip' after resume did nothing")
    }
}
