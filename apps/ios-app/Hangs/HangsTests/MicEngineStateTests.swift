//
//  MicEngineStateTests.swift
//  HangsTests
//
//  #189 — TF feedback 2026-09-29 (AirPods, outside the car, a Slovak quiz):
//  "strange states while answering". Since #184 the command listener's engine
//  is also the answer RECORDER, so anything that treats it as "just the
//  command listener" during a recording makes the answer deaf (H1, H2); a
//  pause must keep the mic shut (M3); the end of the set must take it down
//  (M4); and the Again/Skip sheet belongs to the driver's next decision, not
//  to an answer already sent (M5). Time is a `TestClock`; audio and network
//  are the mocks.
//

import Clocks
import Foundation
@testable import Hangs
import SwiftUI // ScenePhase
import Testing

/// One-shot async gate — holds the mocked listener start in flight.
private actor EngineGate {
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

@Suite("#189 mic engine states — the recorder is the listener")
@MainActor
struct MicEngineStateTests {
    private func makeVM(clock: TestClock<Duration>) -> (QuizViewModel, MockSilenceDetectionService, MockNetworkService, MockAudioService) {
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
        vm.quizState = .askingQuestion
        // #173 seam: no recording window may run out under a test that does
        // not drive it.
        vm.recordingCoordinator.speechStartWindow = 60
        vm.recordingCoordinator.deadAirCap = 60
        return (vm, silence, network, audio)
    }

    // MARK: - H1

    /// WHY (H1): pulling Control Center down mid-answer and letting go brings
    /// the scene back to `.active`, which re-syncs the command window. A
    /// recording is no command screen, so the sync tore the shared engine down
    /// — the engine the answer was being recorded through. The rest of the
    /// answer was never heard. (Minimizing and the Settings toggle hit the
    /// same sync.)
    @Test("H1: a foreground return mid-answer keeps the recorder's mic open")
    func foregroundReturnKeepsRecorderEngine() async {
        let (vm, silence, _, _) = makeVM(clock: TestClock())
        await vm.voiceCommandCoordinator.syncCommandListenerWindow() // the question window armed it…
        await vm.recordingCoordinator.startRecording() // …and the answer records through it
        #expect(vm.quizState == .recording)
        #expect(vm.recordingCoordinator.startedListenerForAnswer == false, "precondition: the window's engine")
        let stopsBefore = silence.stopListeningCallCount

        vm.handleScenePhase(.inactive)
        vm.handleScenePhase(.active)
        // `.active` refreshes fire-and-forget; run the very sync it runs.
        await vm.voiceCommandCoordinator.syncCommandListenerWindow()
        await drain()

        #expect(silence.isListening, "the answer's mic engine was torn down mid-recording")
        #expect(silence.stopListeningCallCount == stopsBefore)
        #expect(silence.isAnswerCaptureActive)
        #expect(vm.quizState == .recording)
    }

    // MARK: - H2

    /// WHY (H2): "Znova" right after the read-back, while the sheet's listener
    /// was still coming up (seconds on Bluetooth). The re-record adopted that
    /// start in flight; when the start landed, its own capture gate saw
    /// `.recording`, judged capture illegal and stopped the engine — the
    /// re-record heard nothing. It had also armed its capture at a guessed
    /// sample rate, before the start picked the real one (8 kHz narrowband).
    @Test("H2: a re-record that adopts a listener start in flight records through it, at its rate")
    func rerecordAdoptsInFlightStart() async {
        let clock = TestClock()
        let (vm, silence, _, audio) = makeVM(clock: clock)
        vm.quizMuteOverride = true // no read-back: the sheet arms its listener at once
        let gate = EngineGate()
        silence.onStartListeningSuspend = {
            silence.isStartingListening = true
            await gate.wait()
            silence.answerAudioSampleRate = 8000 // the narrowband route it found
            silence.isStartingListening = false
        }

        // The answer sheet, its listener start still settling.
        vm.quizState = .processing
        vm.recordingCoordinator.presentVoiceTranscript("Paris")
        await pumpUntil({ silence.isStartingListening }, "the sheet's listener start never began")

        // "Znova": the re-record reaches the engine while the start is in flight.
        vm.recordingCoordinator.rerecordAnswer()
        await pumpUntil({ audio.prepareForRecordingCallCount == 1 }, "the re-record never reached the engine")
        await drain()

        // The start lands.
        await gate.open()
        await pumpUntil({ !silence.isStartingListening }, "the in-flight start never landed")
        await drain()
        // The re-record waits for it on the injected clock (100 ms polls).
        for _ in 0 ..< 10 where !silence.isAnswerCaptureActive {
            await clock.advance(by: .milliseconds(100))
            await drain()
        }

        #expect(silence.isAnswerCaptureActive, "the re-record never armed its capture")
        #expect(silence.isListening, "the start's capture gate stopped the engine the re-record records through")
        #expect(vm.quizState == .recording)
        #expect(vm.recordingCoordinator.startedListenerForAnswer == false, "adopted, not a second start")
        #expect(silence.startListeningCallCount == 1, "one engine, never two (#64)")
        #expect(vm.recordingCoordinator.answerCapture.finish().sampleRate == 8000,
                "the capture was armed before the start picked the real rate")
    }

    // MARK: - M3

    /// WHY (M3): pausing mid-answer submits what was said (#173). When that was
    /// nothing, the empty-answer funnel fired its automatic retry — "didn't
    /// catch that" spoken into a paused quiz, and the mic reopened under the
    /// pause. Paused means silent: Again / Skip, nothing counting down, mic
    /// down (the pause also takes an adopted engine down, #189 H1's exception).
    @Test("M3: pausing an empty recording lands on Again/Skip — no spoken retry, mic down")
    func pausedEmptyRecordingGoesToSheet() async {
        let (vm, silence, network, _) = makeVM(clock: TestClock())
        await vm.voiceCommandCoordinator.syncCommandListenerWindow() // the window's engine…
        await vm.recordingCoordinator.startRecording() // …records the answer
        #expect(vm.recordingCoordinator.startedListenerForAnswer == false, "precondition: the window's engine")

        vm.enterPause() // nothing was said yet

        await pumpUntil({ vm.showAnswerConfirmation }, "a paused empty answer never reached Again/Skip")
        await drain()
        #expect(vm.quizState == .processing)
        #expect(vm.noAnswerCaptured)
        #expect(vm.isPaused, "still paused — the driver resumes")
        #expect(network.synthesizedTexts.isEmpty, "'didn't catch that' spoken into a paused quiz")
        #expect(silence.isListening == false, "the pause must take the recorder's mic down (#173)")
        #expect(silence.isAnswerCaptureActive == false)
        #expect(vm.autoConfirmCountdown == 0)
    }

    /// WHY (M3 + P9): the first miss speaks "didn't catch that" and then
    /// reopens the mic. A pause pressed while that line plays must hold the
    /// re-record — and resuming must give the question its own window back.
    /// The retry sets `isRerecording`, which blocks both the thinking
    /// countdown and the answer timer, so a held retry that kept it set left
    /// the question with no countdown and no mic after resume.
    @Test("M3/P9: a pause during the retry prompt holds the mic; resume re-arms the question")
    func pauseDuringRetryPromptHoldsMic() async {
        let (vm, silence, network, audio) = makeVM(clock: TestClock())
        await vm.recordingCoordinator.startRecording()
        audio.onPlaybackStarted = { [weak vm] in vm?.enterPause() } // pressed while the prompt plays

        await vm.recordingCoordinator.stopRecordingAndSubmit() // nothing was said

        await pumpUntil({ vm.isPaused && !vm.recordingCoordinator.isSpeakingRetryPrompt }, "the retry prompt never played")
        await drain()
        #expect(network.synthesizedTexts == [SpokenPrompt.didNotCatch.text(language: .english)])
        #expect(vm.quizState == .askingQuestion, "the retry reopened the mic under the pause")
        #expect(silence.isAnswerCaptureActive == false)
        #expect(vm.isRerecording == false, "the held retry must not block the question's own window")

        audio.onPlaybackStarted = nil
        vm.exitPause()
        await pumpUntil({ vm.thinkingTimeCountdown == vm.settings.thinkingTime },
                        "resume left the question without its countdown")
    }

    // MARK: - M4

    /// WHY (M4): the last result screen listens for "ďalej"; the natural end
    /// of the set never took that listener down — the mic stayed hot on the
    /// results and the spoken recap played over a live engine (the #64
    /// engine + player pair). The early exit (`endQuizWithResults`) always did.
    @Test("M4: the natural end of the set takes the result screen's mic down")
    func finishQuizStopsListener() async {
        let (vm, silence, _, audio) = makeVM(clock: TestClock())
        vm.settleClock = AnyClock(ImmediateClock()) // a hardware settle, not a quiz timer
        vm.currentSession = Fixtures.makeActiveSession(phase: "finished")
        vm.quizState = .showingResult(
            question: Fixtures.makeQuestion(id: "q_001"),
            evaluation: Evaluation(
                userAnswer: "Paris", result: .correct, points: 1.0,
                correctAnswer: "Paris", questionId: "q_001", explanation: nil
            )
        )
        await vm.audioDeviceState.startSilenceDetectionListening()
        #expect(silence.isListening, "precondition: the result screen listens for 'next'")

        await vm.proceedToNextQuestion()

        #expect(vm.quizState == .finished)
        #expect(silence.isListening == false, "the mic stayed hot on the results")
        #expect(vm.voiceCommandCoordinator.commandCapturePhase == .idle)
        #expect(audio.deactivateSessionCallCount == 1)
    }

    // MARK: - M5

    /// WHY (M5, #185 track G): a typed (or edited) answer the server could not
    /// place goes straight to Again / Skip. That sheet was owned by the typed
    /// answer's attempt — already marked SENT (#186) — so Again and Cancel on
    /// it were both refused as "too late", and the driver could only skip.
    @Test("M5: after a typed answer the server could not place, Again and Cancel work", arguments: [true, false])
    func typedMissSheetAcceptsAgainAndCancel(again: Bool) async {
        let (vm, silence, network, _) = makeVM(clock: TestClock())
        network.submitTextInputError = NetworkError.answerNotCaptured(code: .noAnswer, heard: nil)

        await vm.resubmitAnswer("Pariz") // the typed-answer field

        #expect(vm.showAnswerConfirmation && vm.noAnswerCaptured, "precondition: the Again/Skip sheet")
        if again {
            vm.recordingCoordinator.rerecordAnswer()
            await pumpUntil({ vm.quizState == .recording && silence.isAnswerCaptureActive },
                            "Again was refused on the sheet")
        } else {
            vm.recordingCoordinator.cancelProcessing()
            #expect(vm.quizState == .askingQuestion, "Cancel was refused on the sheet")
            #expect(vm.showAnswerConfirmation == false)
        }
        #expect(!vm.attemptLedger.droppedPaths.contains { $0.hasSuffix("afterAnswerSent") })
        #expect(vm.attemptLedger.invariantViolations.isEmpty)
    }
}
