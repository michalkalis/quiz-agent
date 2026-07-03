//
//  CommandListenerTests.swift
//  HangsTests
//
//  Issue #77 (voice commands hands-free), task 77.5 — the windowed native-English
//  command listener. The Apple recognizer is MOCKED throughout (SpeechAnalyzer's
//  supportedLocales is empty on the Simulator and SpeechDetector is iOS 26+, so
//  the real recognizer can never run headlessly): MockSilenceDetectionService
//  stands in for the transcript source, and these tests exercise the VIEW-MODEL
//  window + consumer + defensive-fallback logic that rides on top of it.
//
//  Coverage:
//    • the window: which screen (if any) listens, per quizState + TTS + recording;
//    • NO arming during TTS or recording;
//    • the consumer: a finalized transcript routes through the screen-scoped
//      matcher and fires onCommandRecognized (screen scoping enforced);
//    • the defensive degrade: a failed recognizer setup / a nil service leaves the
//      manual mic-button flow working, no crash.
//

import Foundation
import Testing
import ConcurrencyExtras
@testable import Hangs

@MainActor
private func makeCommandVM(
    silence: MockSilenceDetectionService? = MockSilenceDetectionService(),
    stt: MockElevenLabsSTTService? = nil
) -> (QuizViewModel, MockSilenceDetectionService?, MockAudioService) {
    let audio = MockAudioService()
    let vm = QuizViewModel(
        networkService: Fixtures.makeFullMockNetwork(),
        audioService: audio,
        persistenceStore: MockPersistenceStore(),
        silenceDetectionService: silence,
        sttService: stt
    )
    vm.currentSession = Fixtures.makeActiveSession()
    vm.currentQuestion = Fixtures.makeQuestion()
    return (vm, silence, audio)
}

/// Spin the main serial executor until `predicate` holds or the deadline passes.
/// Used to pump the AsyncStream → consumer-task → @MainActor handler hops.
@MainActor
private func waitUntil(
    _ predicate: @MainActor () -> Bool,
    timeoutMillis: Int = 5_000,
    _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMillis))
    while ContinuousClock.now < deadline {
        if predicate() { return }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
    if predicate() { return }
    Issue.record(comment ?? "waitUntil timed out after \(timeoutMillis)ms", sourceLocation: sourceLocation)
}

@MainActor
private func makeResultState() -> QuizState {
    .showingResult(
        question: Fixtures.makeQuestion(),
        evaluation: Evaluation(
            userAnswer: "x", result: .correct, points: 1.0,
            correctAnswer: "x", questionId: "q_001", explanation: nil
        )
    )
}

@Suite("Command listener — window + consumer + defensive fallback")
@MainActor
struct CommandListenerTests {

    // MARK: - Window mapping

    @Test("currentCommandScreen maps each listening state, nil elsewhere")
    func windowMapping() {
        let (vm, _, _) = makeCommandVM()

        vm.quizState = .idle
        #expect(vm.currentCommandScreen == .home)

        vm.quizState = .askingQuestion
        #expect(vm.currentCommandScreen == .question)

        vm.quizState = .processing
        #expect(vm.currentCommandScreen == .confirmation)

        vm.quizState = makeResultState()
        #expect(vm.currentCommandScreen == .result)

        // Non-listening states → nil (never armed).
        vm.quizState = .recording
        #expect(vm.currentCommandScreen == nil)
        vm.quizState = .startingQuiz
        #expect(vm.currentCommandScreen == nil)
        vm.quizState = .finished
        #expect(vm.currentCommandScreen == nil)
    }

    @Test("the window is CLOSED during question TTS (self-trigger guard)")
    func windowClosedDuringTTS() {
        let (vm, _, _) = makeCommandVM()
        vm.quizState = .askingQuestion
        #expect(vm.currentCommandScreen == .question)

        vm.isPlayingQuestionTTS = true
        #expect(vm.currentCommandScreen == nil, "listener must be torn down while TTS plays")

        vm.isPlayingQuestionTTS = false
        #expect(vm.currentCommandScreen == .question)
    }

    // MARK: - Arm / tear-down per state

    @Test("syncCommandListenerWindow arms on a listening screen and tears down otherwise")
    func syncArmsAndTearsDown() async {
        let (vm, silence, _) = makeCommandVM()
        let mock = try! #require(silence)

        vm.quizState = .askingQuestion
        await vm.syncCommandListenerWindow()
        #expect(mock.isListening == true)

        // Recording → torn down (NEVER armed during recording).
        vm.quizState = .recording
        await vm.syncCommandListenerWindow()
        #expect(mock.isListening == false)

        // Result → armed again.
        vm.quizState = makeResultState()
        await vm.syncCommandListenerWindow()
        #expect(mock.isListening == true)
    }

    @Test("syncCommandListenerWindow does NOT arm during TTS")
    func noArmDuringTTS() async {
        let (vm, silence, _) = makeCommandVM()
        let mock = try! #require(silence)

        vm.quizState = .askingQuestion
        vm.isPlayingQuestionTTS = true
        await vm.syncCommandListenerWindow()
        #expect(mock.isListening == false, "listener must stay down while TTS is playing")
    }

    @Test("entering .recording tears down the listener (never both mic-command + answer)")
    func recordingTearsDownListener() async {
        let (vm, silence, _) = makeCommandVM()
        let mock = try! #require(silence)

        vm.quizState = .askingQuestion
        await vm.startSilenceDetectionListening()
        #expect(mock.isListening == true)

        // Simulate the answer window opening.
        vm.quizState = .recording
        await vm.syncCommandListenerWindow()
        #expect(mock.isListening == false)
    }

    // MARK: - Consumer routing (screen-scoped)

    @Test("a finalized transcript routes through the matcher and fires the recognition hook")
    func consumerRoutesRecognizedCommand() async {
        await withMainSerialExecutor {
            let (vm, silence, _) = makeCommandVM()
            let mock = try! #require(silence)

            var recognized: [VoiceCommand] = []
            vm.onCommandRecognized = { recognized.append($0) }

            vm.quizState = .askingQuestion
            await vm.startSilenceDetectionListening() // arms the consumer

            mock.simulateCommandTranscript("start")
            await waitUntil({ !recognized.isEmpty }, "no command recognized")

            #expect(recognized == [.start])
        }
    }

    @Test("screen scoping: 'next' is inert on the question screen, valid on result")
    func consumerScreenScoping() async {
        await withMainSerialExecutor {
            let (vm, silence, _) = makeCommandVM()
            let mock = try! #require(silence)

            var recognized: [VoiceCommand] = []
            vm.onCommandRecognized = { recognized.append($0) }

            // "next" is NOT a question-screen command → dropped.
            vm.quizState = .askingQuestion
            await vm.startSilenceDetectionListening()
            mock.simulateCommandTranscript("next")
            // Give the consumer a chance to (not) fire.
            for _ in 0..<20 { await Task.yield() }
            #expect(recognized.isEmpty, "‘next’ must not match on the question screen")

            // On the result screen, "next" matches.
            vm.quizState = makeResultState()
            mock.simulateCommandTranscript("next")
            await waitUntil({ !recognized.isEmpty }, "‘next’ never matched on result")
            #expect(recognized == [.next])
        }
    }

    @Test("a non-command transcript produces no recognition")
    func consumerIgnoresNonCommand() async {
        await withMainSerialExecutor {
            let (vm, silence, _) = makeCommandVM()
            let mock = try! #require(silence)

            var recognized: [VoiceCommand] = []
            vm.onCommandRecognized = { recognized.append($0) }

            vm.quizState = .askingQuestion
            await vm.startSilenceDetectionListening()
            mock.simulateCommandTranscript("what is the capital of france")
            for _ in 0..<20 { await Task.yield() }
            #expect(recognized.isEmpty)
        }
    }

    @Test("startCommandConsumer drives the capture phase idle → listening; stop resets to idle")
    func consumerDrivesCapturePhase() async {
        let (vm, _, _) = makeCommandVM()
        #expect(vm.commandCapturePhase == .idle)

        vm.quizState = .askingQuestion
        await vm.startSilenceDetectionListening()
        #expect(vm.commandCapturePhase == .listening)

        vm.stopSilenceDetectionListening()
        #expect(vm.commandCapturePhase == .idle)
    }

    // MARK: - Defensive degrade to buttons (E-fallback)

    @Test("a failed recognizer setup leaves button-only mode: no crash, buttons work")
    func failedSetupDegradesToButtons() async {
        let (vm, silence, audio) = makeCommandVM()
        let mock = try! #require(silence)
        mock.shouldFailSetup = true

        vm.quizState = .askingQuestion
        await vm.syncCommandListenerWindow()
        // Setup failed → listener stays DOWN, no command layer, no crash.
        #expect(mock.isListening == false)
        #expect(mock.startListeningCallCount >= 1, "setup was attempted")

        // The manual mic button still works (batch path — no STT service).
        await vm.startRecording()
        #expect(vm.quizState == .recording)
        #expect(audio.isRecording == true)
    }

    @Test("a nil recognizer service is a no-op; the manual mic button still works")
    func nilServiceIsButtonOnly() async {
        let (vm, _, audio) = makeCommandVM(silence: nil)

        vm.quizState = .askingQuestion
        await vm.syncCommandListenerWindow() // must not crash
        #expect(vm.currentCommandScreen == .question) // window logic still computes

        await vm.startRecording()
        #expect(vm.quizState == .recording)
        #expect(audio.isRecording == true)
    }
}
