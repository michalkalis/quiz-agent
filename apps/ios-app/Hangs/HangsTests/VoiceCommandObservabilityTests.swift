//
//  VoiceCommandObservabilityTests.swift
//  HangsTests
//
//  Issue #96 P2 — voice-command observability. Covers the founder-facing pieces
//  added on top of the #77 listener: the master Settings toggle (gates the whole
//  command window), the on-screen "LISTENING FOR COMMANDS" indicator hint (the
//  words shown per screen), the release diagnostics (last recognized command),
//  and the persisted-settings backward-compat for the re-introduced toggle.
//
//  The Apple recognizer is MOCKED (SpeechAnalyzer can't run headlessly), exactly
//  as in CommandListenerTests — these assert the view-model + lexicon logic.
//

import ConcurrencyExtras
import Foundation
@testable import Hangs
import Testing

@MainActor
private func makeVM(
    silence: MockSilenceDetectionService = MockSilenceDetectionService()
) -> (QuizViewModel, MockSilenceDetectionService, MockAudioService) {
    let audio = MockAudioService()
    let vm = QuizViewModel(
        networkService: Fixtures.makeFullMockNetwork(),
        audioService: audio,
        persistenceStore: MockPersistenceStore(),
        silenceDetectionService: silence,
        sttService: nil
    )
    vm.currentSession = Fixtures.makeActiveSession()
    vm.currentQuestion = Fixtures.makeQuestion()
    return (vm, silence, audio)
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

@MainActor
private func waitUntil(
    _ predicate: @MainActor () -> Bool,
    timeoutMillis: Int = 5000,
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

@Suite("Voice command observability (#96 P2)")
@MainActor
struct VoiceCommandObservabilityTests {
    // MARK: - Indicator hint copy

    @Test("lexicon hint names the valid words for each screen")
    func lexiconHints() {
        #expect(VoiceCommandLexicon.hint(on: .home) == #"Say "start""#)
        #expect(VoiceCommandLexicon.hint(on: .question) == #"Say "start" or "skip""#)
        #expect(VoiceCommandLexicon.hint(on: .confirmation) == #"Say "ok", "again" or "stop""#)
        #expect(VoiceCommandLexicon.hint(on: .result) == #"Say "next""#)
    }

    @Test("commandListenerHint is nil until listening, then names the screen's words")
    func hintTracksListeningWindow() async {
        let (vm, _, _) = makeVM()
        vm.quizState = .idle
        #expect(vm.commandListenerHint == nil, "not listening yet → no indicator")

        await vm.audioDeviceState.startSilenceDetectionListening() // arms the consumer → .listening
        #expect(vm.voiceCommandCoordinator.commandCapturePhase == .listening)
        #expect(vm.commandListenerHint == #"Say "start""#)

        // Moving to the result screen swaps the words shown.
        vm.quizState = makeResultState()
        #expect(vm.commandListenerHint == #"Say "next""#)

        // Tearing the listener down hides the indicator.
        vm.audioDeviceState.stopSilenceDetectionListening()
        #expect(vm.commandListenerHint == nil)
    }

    @Test("indicator stays hidden when the recognizer is unavailable (never lies)")
    func hintHiddenWhenRecognizerUnavailable() async {
        let (vm, silence, _) = makeVM()
        let mock = silence
        mock.commandAvailability = .unavailable(reason: "assets missing")
        // Availability now mirrors through an async stream — wait for the VM to
        // observe it before asserting on the derived hint.
        await waitUntil({ vm.commandAvailability == .unavailable(reason: "assets missing") },
                        "availability mirror did not pick up the unavailable state")

        vm.quizState = .idle
        await vm.audioDeviceState.startSilenceDetectionListening()
        #expect(vm.voiceCommandCoordinator.commandCapturePhase == .listening, "the consumer still arms")
        #expect(vm.commandListenerHint == nil, "but the cue must not claim to be listening")
    }

    // The bug this fixes: on a fresh install the en-US model installs
    // asynchronously; Home arms the listener while availability is still
    // `.installingAssets`, so the indicator is (correctly) hidden. When the
    // install completes the service flips to `.ready` — but that was a plain,
    // non-observable property, so SwiftUI never re-rendered and the
    // "LISTENING FOR COMMANDS" bar stayed hidden even though commands then
    // worked. The observable mirror must pick up the mid-session flip so the
    // hint (nil → shown) reacts live.
    @Test("a mid-session .ready flip updates the observed availability and reveals the hint")
    func availabilityReadyFlipRevealsHint() async {
        let (vm, silence, _) = makeVM()
        let mock = silence

        // Fresh-install: still installing → listener arms, indicator hidden.
        mock.commandAvailability = .installingAssets
        await waitUntil({ vm.commandAvailability == .installingAssets },
                        "mirror did not observe the installing state")

        vm.quizState = .idle
        await vm.audioDeviceState.startSilenceDetectionListening()
        #expect(vm.voiceCommandCoordinator.commandCapturePhase == .listening)
        #expect(vm.commandListenerHint == nil, "installing → the cue must not claim to be listening yet")

        // Model install completes asynchronously → service flips to .ready.
        mock.commandAvailability = .ready
        await waitUntil({ vm.commandAvailability == .ready },
                        "the observable mirror did not pick up the .ready flip")
        #expect(vm.commandListenerHint == #"Say "start""#, "ready → the Home hint must now appear")
    }

    // MARK: - Master toggle

    @Test("master toggle off → no command window on any screen (buttons only)")
    func masterToggleGatesWindow() {
        let (vm, _, _) = makeVM()
        vm.settings.voiceCommandsEnabled = false
        for state in [QuizState.idle, .askingQuestion, .processing, makeResultState()] {
            vm.quizState = state
            #expect(vm.voiceCommandCoordinator.currentCommandScreen == nil, "toggle off must close the window in every state")
        }
        // Re-enabling restores the normal mapping.
        vm.settings.voiceCommandsEnabled = true
        vm.quizState = .idle
        #expect(vm.voiceCommandCoordinator.currentCommandScreen == .home)
    }

    @Test("disabling the toggle tears down an already-armed listener")
    func toggleTearsDownArmed() async {
        let (vm, silence, _) = makeVM()
        let mock = silence

        vm.quizState = .askingQuestion
        await vm.voiceCommandCoordinator.syncCommandListenerWindow()
        #expect(mock.isListening == true)

        vm.settings.voiceCommandsEnabled = false
        await vm.voiceCommandCoordinator.syncCommandListenerWindow()
        #expect(mock.isListening == false, "the master toggle must stop the running listener")
    }

    @Test("master toggle off suppresses the indicator even mid-listen")
    func toggleOffSuppressesHint() async {
        let (vm, _, _) = makeVM()
        vm.quizState = .idle
        await vm.audioDeviceState.startSilenceDetectionListening()
        #expect(vm.commandListenerHint != nil)

        vm.settings.voiceCommandsEnabled = false
        #expect(vm.commandListenerHint == nil, "toggle off closes the window → no hint")
    }

    // MARK: - Release diagnostics

    @Test("recognizing a command records it for the diagnostics row")
    func lastRecognizedCommandRecorded() async {
        await withMainSerialExecutor {
            let (vm, silence, _) = makeVM()
            let mock = silence
            #expect(vm.lastRecognizedCommand == nil)

            vm.quizState = .idle // Home — spoken "start" is valid
            await vm.audioDeviceState.startSilenceDetectionListening()
            mock.simulateCommandTranscript("start")
            await waitUntil({ vm.lastRecognizedCommand != nil }, "no command recorded")

            #expect(vm.lastRecognizedCommand == .start)
        }
    }

    // MARK: - Persisted settings backward-compat

    @Test("voiceCommandsEnabled defaults to true when absent from persisted settings")
    func settingsDefaultsWhenAbsent() throws {
        // A pre-#96 blob with none of the newer keys must still decode, ON.
        let json = """
        {"language":"en","audioMode":"media","numberOfQuestions":10,
         "difficulty":"medium","autoAdvanceDelay":8,"answerTimeLimit":30}
        """
        let decoded = try JSONDecoder().decode(QuizSettings.self, from: Data(json.utf8))
        #expect(decoded.voiceCommandsEnabled == true)
    }

    @Test("voiceCommandsEnabled survives an encode/decode round-trip")
    func settingsRoundTrip() throws {
        var settings = QuizSettings.default
        settings.voiceCommandsEnabled = false
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(QuizSettings.self, from: data)
        #expect(decoded.voiceCommandsEnabled == false)
    }
}
