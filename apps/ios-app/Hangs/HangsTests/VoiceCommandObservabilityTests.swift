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

@Suite("Voice command observability (#96 P2)")
@MainActor
struct VoiceCommandObservabilityTests {
    // MARK: - Indicator hint copy

    /// #174: the hint names exactly the words printed on the screen's buttons
    /// (Confirm / Again) — one vocabulary, seen and heard. #185: the answer
    /// sheet also says a new answer can simply be spoken (5.1), and the
    /// no-answer sheet names ITS buttons (Again / Skip), not Confirm.
    @Test("lexicon hint names the valid words for each screen")
    func lexiconHints() {
        #expect(VoiceCommandLexicon.hint(on: .home) == #"Say "start""#)
        #expect(VoiceCommandLexicon.hint(on: .question) == #"Say "start" or "skip""#)
        #expect(VoiceCommandLexicon.hint(on: .confirmation) == #"Say "confirm", "again" or a new answer"#)
        #expect(VoiceCommandLexicon.hint(on: .noAnswer) == #"Say "again" or "skip""#)
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
        await pumpUntil({ vm.commandAvailability == .unavailable(reason: "assets missing") },
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
        await pumpUntil({ vm.commandAvailability == .installingAssets },
                        "mirror did not observe the installing state")

        vm.quizState = .idle
        await vm.audioDeviceState.startSilenceDetectionListening()
        #expect(vm.voiceCommandCoordinator.commandCapturePhase == .listening)
        #expect(vm.commandListenerHint == nil, "installing → the cue must not claim to be listening yet")

        // Model install completes asynchronously → service flips to .ready.
        mock.commandAvailability = .ready
        await pumpUntil({ vm.commandAvailability == .ready },
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
            await pumpUntil({ vm.lastRecognizedCommand != nil }, "no command recorded")

            #expect(vm.lastRecognizedCommand == .start)
        }
    }

    // MARK: - Drop-log sampling + raw-speech gating

    /// WHY: the producer samples its volatile telemetry to one event per segment
    /// precisely because volatiles arrive on every hypothesis change. The consumer
    /// logged one event per transcript at every drop exit, so a drive with the
    /// radio on reproduced the exact volume the producer's sampling was written to
    /// avoid — and the events crowded out are the "voice cmd matched"/`sincePrevMs`
    /// ones that are the only field confirmation of the off-device measurement.
    @Test("only the first volatile of an utterance may spend a drop-log event")
    func dropLogSamplesVolatilesPerUtterance() {
        let (vm, _, _) = makeVM()
        let coordinator = vm.voiceCommandCoordinator

        #expect(coordinator.shouldLogDroppedTranscript(isFinal: false), "first volatile is the sample")
        #expect(coordinator.shouldLogDroppedTranscript(isFinal: false) == false, "every later volatile is dropped silently")
        #expect(coordinator.shouldLogDroppedTranscript(isFinal: false) == false)
        #expect(coordinator.shouldLogDroppedTranscript(isFinal: true), "a final is low-frequency — always logged")

        // The final ended the utterance, so the next one gets its own sample.
        coordinator.endUtterance()
        #expect(coordinator.shouldLogDroppedTranscript(isFinal: false), "the next utterance is sampled afresh")
    }

    /// WHY (#185 3.5, founder 2026-09-24): commands that did not fire could not
    /// be debugged from Sentry, because only the text LENGTH was logged — so
    /// TestFlight and debug builds now log what the recognizer heard (and a
    /// final's alternatives). The App Store build keeps the no-raw-speech rule
    /// of Logging.swift: that half of the gate is the privacy invariant, and
    /// the Settings switch has no say in it either way.
    @Test("drop logs carry what was heard in TestFlight/debug builds only")
    func dropLogTextFollowsBuildChannel() {
        let (vm, _, _) = makeVM()
        let coordinator = vm.voiceCommandCoordinator
        let heard = CommandTranscript(text: "Start now", isFinal: true, alternatives: ["star now"])

        let appStore = coordinator.droppedTranscriptAttributes(
            heard, normalized: "start now", tokens: 2, sincePrevMs: 420, logsText: false
        )
        #expect(appStore["text"] == nil, "an App Store build must never upload what the driver said")
        #expect(appStore["alternatives"] == nil)
        #expect(appStore["len"] as? Int == 9, "the metadata that makes the event triageable stays")
        #expect(appStore["sincePrevMs"] as? Int == 420)

        let testFlight = coordinator.droppedTranscriptAttributes(
            heard, normalized: "start now", tokens: 2, sincePrevMs: 420, logsText: true
        )
        #expect(testFlight["text"] as? String == "Start now", "raw recognizer text, diacritics and all")
        #expect(testFlight["alternatives"] as? String == "star now")

        #expect(VoiceCommandCoordinator.heardTextAttributes("stop", enabled: false).isEmpty)
        #expect(VoiceCommandCoordinator.heardTextAttributes("stop", enabled: true)["text"] as? String == "stop")
        // The gate itself is the build channel, not a Settings toggle.
        #expect(VoiceCommandCoordinator.logsHeardText == BuildChannel.debugSurfacesEnabled())
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
