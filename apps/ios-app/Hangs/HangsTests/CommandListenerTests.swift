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
//    • the consumer: a transcript routes through the screen-scoped
//      matcher and fires onCommandRecognized (screen scoping enforced);
//    • #110 volatile results: at most ONE command per utterance, destructive
//      commands only from a final result, a volatile having to be DELIVERED
//      TWICE UNCHANGED before it may fire (so a growing sentence's one-word
//      prefix can't), the same-command cooldown, and the window being closed
//      during feedback TTS as well as question TTS;
//    • the defensive degrade: a failed recognizer setup / a nil service leaves the
//      manual mic-button flow working, no crash.
//

import ConcurrencyExtras
import Foundation
@testable import Hangs
import Testing

@MainActor
private func makeCommandVM(
    silence: MockSilenceDetectionService = MockSilenceDetectionService(),
    stt: MockElevenLabsSTTService? = nil
) -> (QuizViewModel, MockSilenceDetectionService, MockAudioService) {
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

/// Driven clock for the command cooldown (#110). A reference box so the test can
/// move "now" forward without a real `Task.sleep` — the repo's three flaky async
/// voice tests all came from sleeping in tests.
@MainActor
private final class TestClock {
    var now: Date
    init(_ now: Date) { self.now = now }
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
        #expect(vm.voiceCommandCoordinator.currentCommandScreen == .home)

        vm.quizState = .askingQuestion
        #expect(vm.voiceCommandCoordinator.currentCommandScreen == .question)

        vm.quizState = .processing
        #expect(vm.voiceCommandCoordinator.currentCommandScreen == .confirmation)

        vm.quizState = makeResultState()
        #expect(vm.voiceCommandCoordinator.currentCommandScreen == .result)

        // Non-listening states → nil (never armed).
        vm.quizState = .recording
        #expect(vm.voiceCommandCoordinator.currentCommandScreen == nil)
        vm.quizState = .startingQuiz
        #expect(vm.voiceCommandCoordinator.currentCommandScreen == nil)
        vm.quizState = .finished
        #expect(vm.voiceCommandCoordinator.currentCommandScreen == nil)
    }

    @Test("the window is CLOSED during question TTS (self-trigger guard)")
    func windowClosedDuringTTS() {
        let (vm, _, _) = makeCommandVM()
        vm.quizState = .askingQuestion
        #expect(vm.voiceCommandCoordinator.currentCommandScreen == .question)

        vm.isPlayingQuestionTTS = true
        #expect(vm.voiceCommandCoordinator.currentCommandScreen == nil, "listener must be torn down while TTS plays")

        vm.isPlayingQuestionTTS = false
        #expect(vm.voiceCommandCoordinator.currentCommandScreen == .question)
    }

    // MARK: - Arm / tear-down per state

    @Test("syncCommandListenerWindow arms on a listening screen and tears down otherwise")
    func syncArmsAndTearsDown() async {
        let (vm, silence, _) = makeCommandVM()
        let mock = silence

        vm.quizState = .askingQuestion
        await vm.voiceCommandCoordinator.syncCommandListenerWindow()
        #expect(mock.isListening == true)

        // Recording → torn down (NEVER armed during recording).
        vm.quizState = .recording
        await vm.voiceCommandCoordinator.syncCommandListenerWindow()
        #expect(mock.isListening == false)

        // Result → armed again.
        vm.quizState = makeResultState()
        await vm.voiceCommandCoordinator.syncCommandListenerWindow()
        #expect(mock.isListening == true)
    }

    @Test("syncCommandListenerWindow does NOT arm during TTS")
    func noArmDuringTTS() async {
        let (vm, silence, _) = makeCommandVM()
        let mock = silence

        vm.quizState = .askingQuestion
        vm.isPlayingQuestionTTS = true
        await vm.voiceCommandCoordinator.syncCommandListenerWindow()
        #expect(mock.isListening == false, "listener must stay down while TTS is playing")
    }

    @Test("entering .recording tears down the listener (never both mic-command + answer)")
    func recordingTearsDownListener() async {
        let (vm, silence, _) = makeCommandVM()
        let mock = silence

        vm.quizState = .askingQuestion
        await vm.audioDeviceState.startSilenceDetectionListening()
        #expect(mock.isListening == true)

        // Simulate the answer window opening.
        vm.quizState = .recording
        await vm.voiceCommandCoordinator.syncCommandListenerWindow()
        #expect(mock.isListening == false)
    }

    // MARK: - Consumer routing (screen-scoped)

    @Test("a finalized transcript routes through the matcher and fires the recognition hook")
    func consumerRoutesRecognizedCommand() async {
        await withMainSerialExecutor {
            let (vm, silence, _) = makeCommandVM()
            let mock = silence

            var recognized: [VoiceCommand] = []
            vm.voiceCommandCoordinator.onCommandRecognized = { recognized.append($0) }

            vm.quizState = .askingQuestion
            await vm.audioDeviceState.startSilenceDetectionListening() // arms the consumer

            mock.simulateCommandTranscript("start")
            await waitUntil({ !recognized.isEmpty }, "no command recognized")

            #expect(recognized == [.start])
        }
    }

    @Test("screen scoping: 'next' is inert on the question screen, valid on result")
    func consumerScreenScoping() async {
        await withMainSerialExecutor {
            let (vm, silence, _) = makeCommandVM()
            let mock = silence

            var recognized: [VoiceCommand] = []
            vm.voiceCommandCoordinator.onCommandRecognized = { recognized.append($0) }

            // "next" is NOT a question-screen command → dropped.
            vm.quizState = .askingQuestion
            await vm.audioDeviceState.startSilenceDetectionListening()
            mock.simulateCommandTranscript("next")
            // Give the consumer a chance to (not) fire.
            for _ in 0 ..< 20 {
                await Task.yield()
            }
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
            let mock = silence

            var recognized: [VoiceCommand] = []
            vm.voiceCommandCoordinator.onCommandRecognized = { recognized.append($0) }

            vm.quizState = .askingQuestion
            await vm.audioDeviceState.startSilenceDetectionListening()
            mock.simulateCommandTranscript("what is the capital of france")
            for _ in 0 ..< 20 {
                await Task.yield()
            }
            #expect(recognized.isEmpty)
        }
    }

    @Test("startCommandConsumer drives the capture phase idle → listening; stop resets to idle")
    func consumerDrivesCapturePhase() async {
        let (vm, _, _) = makeCommandVM()
        #expect(vm.voiceCommandCoordinator.commandCapturePhase == .idle)

        vm.quizState = .askingQuestion
        await vm.audioDeviceState.startSilenceDetectionListening()
        #expect(vm.voiceCommandCoordinator.commandCapturePhase == .listening)

        vm.audioDeviceState.stopSilenceDetectionListening()
        #expect(vm.voiceCommandCoordinator.commandCapturePhase == .idle)
    }

    // MARK: - Volatile results: one command per utterance (#110)

    /// WHY: the transcriber now reports a GROWING volatile hypothesis several
    /// times per utterance (the build-33 latency fix — waiting for the
    /// end-of-speech endpoint meant the first "start" never fired). Field data
    /// shows the founder repeating himself when nothing responds
    /// ("start start start start start"), so firing per hypothesis would run the
    /// action once per repeat.
    @Test("a repeated volatile 'start' fires once; later transcripts of the same utterance do not")
    func volatileFiresOncePerUtterance() async {
        await withMainSerialExecutor {
            let (vm, silence, _) = makeCommandVM()
            let mock = silence

            var recognized: [VoiceCommand] = []
            vm.voiceCommandCoordinator.onCommandRecognized = { recognized.append($0) }

            // Routing is deliberately inert (the P4a flag is off) so the screen
            // never changes: the ONLY thing that can stop the 2nd/3rd fire is
            // the utterance latch.
            vm.voiceCommandCoordinator.voiceStartOnQuestionEnabled = false
            vm.quizState = .askingQuestion
            await vm.audioDeviceState.startSilenceDetectionListening() // arms the consumer

            mock.simulateCommandTranscript("start", isFinal: false)
            for _ in 0 ..< 20 {
                await Task.yield()
            }
            #expect(recognized.isEmpty, "an unproven first hypothesis must not fire — every sentence has a prefix")

            // Re-emitted unchanged while he is silent: THAT is what proves it was
            // a one-word command, and it still lands long before the end-of-speech
            // endpoint — the latency fix survives the stability gate.
            mock.simulateCommandTranscript("start", isFinal: false)
            await waitUntil({ !recognized.isEmpty }, "a repeated volatile hypothesis must fire")

            // The hypothesis keeps growing as he repeats himself, then finalizes.
            mock.simulateCommandTranscript("start start", isFinal: false)
            mock.simulateCommandTranscript("start start start", isFinal: true)
            for _ in 0 ..< 40 {
                await Task.yield()
            }

            #expect(recognized == [.start], "one utterance = at most one command, got \(recognized)")
        }
    }

    /// WHY (#110, the hole the content-token cap structurally cannot see): the
    /// cap is evaluated on ONE delivered transcript, but the transcriber emits a
    /// GROWING hypothesis — so every utterance passes through a 1-token prefix
    /// state and the cap is a no-op on the leading edge of ALL speech. Without a
    /// stability gate, "Okay, tak to bolo dobré" from the passenger advances the
    /// quiz ~300 ms in, and a radio "Starting now…" starts one. A sentence never
    /// presents the same hypothesis twice — it keeps growing.
    @Test("a growing sentence's one-word prefix never fires")
    func growingSentencePrefixDoesNotFire() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeCommandVM()
            let coordinator = vm.voiceCommandCoordinator
            vm.quizState = makeResultState()

            var recognized: [VoiceCommand] = []
            coordinator.onCommandRecognized = { recognized.append($0) }

            for hypothesis in ["okay", "okay tak", "okay tak to", "okay tak to bolo dobre"] {
                await coordinator.handleCommandTranscript(CommandTranscript(text: hypothesis, isFinal: false))
            }
            await coordinator.handleCommandTranscript(
                CommandTranscript(text: "okay tak to bolo dobre", isFinal: true)
            )

            #expect(recognized.isEmpty, "conversational speech must not advance the quiz, got \(recognized)")
        }
    }

    /// WHY: a volatile hypothesis is revisable — the transcriber may replace it
    /// as more audio arrives — and a skip burns one of the 100 free questions a
    /// month. Destructive commands must wait for the final result.
    @Test("'skip' fires only from a final result, never from a volatile hypothesis")
    func skipRequiresFinalResult() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeCommandVM()
            let coordinator = vm.voiceCommandCoordinator
            vm.quizState = .askingQuestion

            var recognized: [VoiceCommand] = []
            coordinator.onCommandRecognized = { recognized.append($0) }

            await coordinator.handleCommandTranscript(CommandTranscript(text: "skip", isFinal: false))
            #expect(recognized.isEmpty, "a revisable hypothesis must never burn a question")
            #expect(coordinator.pendingSkipWindow == nil)

            await coordinator.handleCommandTranscript(CommandTranscript(text: "skip", isFinal: true))
            #expect(recognized == [.skip], "the final result commits the skip")
            #expect(coordinator.pendingSkipWindow != nil, "…via the 2.5 s undo-window")

            coordinator.abortSkipUndoWindow() // don't let the window commit after the test
        }
    }

    /// WHY: both discard an answer irreversibly — `again` throws away the
    /// transcribed answer, `stop` cancels the in-flight evaluation — so neither
    /// may act on a hypothesis the transcriber can still revise. (`ok` on this
    /// sheet is held to the same rule, for the opposite reason — see
    /// `okRequiresFinalOnConfirmationOnly`.)
    @Test("volatile 'again' / 'stop' on the confirmation sheet do not fire; finals do")
    func destructiveConfirmationCommandsRequireFinal() async {
        await withMainSerialExecutor {
            for (text, expected) in [("again", VoiceCommand.again), ("stop", VoiceCommand.stop)] {
                let (vm, _, _) = makeCommandVM()
                let coordinator = vm.voiceCommandCoordinator
                vm.quizState = .processing // the confirmation sheet

                var recognized: [VoiceCommand] = []
                coordinator.onCommandRecognized = { recognized.append($0) }

                await coordinator.handleCommandTranscript(CommandTranscript(text: text, isFinal: false))
                #expect(recognized.isEmpty, "'\(text)' must not discard an answer from a revisable hypothesis")

                await coordinator.handleCommandTranscript(CommandTranscript(text: text, isFinal: true))
                #expect(recognized == [expected], "'\(text)' must still work on the final result")
            }
        }
    }

    /// WHY: within ONE utterance an early hypothesis can resolve to one command
    /// and a later one to another — on the question screen that would open the
    /// mic and then burn the question. The first command wins and the utterance
    /// is closed to the rest.
    @Test("two different commands resolved from one utterance fire at most once")
    func twoCommandsInOneUtteranceFireOnce() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeCommandVM()
            let coordinator = vm.voiceCommandCoordinator
            // Inert routing (see volatileFiresOncePerUtterance) so the screen stays open.
            coordinator.voiceStartOnQuestionEnabled = false
            vm.quizState = .askingQuestion

            var recognized: [VoiceCommand] = []
            coordinator.onCommandRecognized = { recognized.append($0) }

            // Same hypothesis twice → proven, so the benign `start` fires.
            await coordinator.handleCommandTranscript(CommandTranscript(text: "start", isFinal: false))
            await coordinator.handleCommandTranscript(CommandTranscript(text: "start", isFinal: false))
            #expect(recognized == [.start])
            #expect(coordinator.commandFiredThisUtterance, "the latch is what must block what follows")

            await coordinator.handleCommandTranscript(CommandTranscript(text: "skip", isFinal: true))

            #expect(recognized == [.start], "the same utterance must not also burn the question, got \(recognized)")
            #expect(coordinator.pendingSkipWindow == nil)
        }
    }

    /// WHY (#110): `ok` on the confirmation sheet SUBMITS the answer. The 10 s
    /// auto-confirm does NOT make that benign — that timer exists precisely so a
    /// wrong transcription can be caught with "again", and firing `ok` from a
    /// revisable hypothesis removes the escape before the founder can use it.
    /// "okay" is the highest-frequency backchannel in conversation, and `again`
    /// (the escape) waits for a final, so ambient speech would otherwise race
    /// the correction and win. On the RESULT screen `ok` stays benign: advancing
    /// is the default outcome there anyway.
    @Test("'ok' requires a final on the confirmation sheet, but not on the result")
    func okRequiresFinalOnConfirmationOnly() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeCommandVM()
            let coordinator = vm.voiceCommandCoordinator
            vm.quizState = .processing // the confirmation sheet

            var recognized: [VoiceCommand] = []
            coordinator.onCommandRecognized = { recognized.append($0) }

            // Even a STABLE volatile (delivered twice unchanged) must not submit.
            await coordinator.handleCommandTranscript(CommandTranscript(text: "okay", isFinal: false))
            await coordinator.handleCommandTranscript(CommandTranscript(text: "okay", isFinal: false))
            #expect(recognized.isEmpty, "a revisable hypothesis must not submit the answer")

            await coordinator.handleCommandTranscript(CommandTranscript(text: "okay", isFinal: true))
            #expect(recognized == [.ok], "the final still confirms")

            // The result screen keeps the low-latency volatile path.
            let (resultVM, _, _) = makeCommandVM()
            let resultCoordinator = resultVM.voiceCommandCoordinator
            resultVM.quizState = makeResultState()
            var advanced: [VoiceCommand] = []
            resultCoordinator.onCommandRecognized = { advanced.append($0) }

            await resultCoordinator.handleCommandTranscript(CommandTranscript(text: "okay", isFinal: false))
            await resultCoordinator.handleCommandTranscript(CommandTranscript(text: "okay", isFinal: false))
            #expect(advanced == [.ok], "advancing early is the default outcome — no reason to wait")
        }
    }

    /// WHY: one spoken word can arrive as two utterances (he repeats himself
    /// when nothing seems to happen), which the per-utterance latch cannot see.
    /// The cooldown is the second layer. Driven clock — no `Task.sleep`.
    @Test("the cooldown suppresses a same-command repeat inside the window and allows it after")
    func cooldownSuppressesSameCommandRepeat() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeCommandVM()
            let coordinator = vm.voiceCommandCoordinator
            let clock = TestClock(Date())
            let base = clock.now
            coordinator.now = { clock.now }

            // Inert routing (see volatileFiresOncePerUtterance) so the screen stays open.
            coordinator.voiceStartOnQuestionEnabled = false
            vm.quizState = .askingQuestion

            var recognized: [VoiceCommand] = []
            coordinator.onCommandRecognized = { recognized.append($0) }

            await coordinator.handleCommandTranscript(CommandTranscript(text: "start", isFinal: true))
            #expect(recognized == [.start])

            clock.now = base.addingTimeInterval(0.5) // still inside the cooldown
            await coordinator.handleCommandTranscript(CommandTranscript(text: "start", isFinal: true))
            #expect(recognized == [.start], "a repeat inside the cooldown must not fire twice, got \(recognized)")

            clock.now = base.addingTimeInterval(VoiceCommandCoordinator.commandCooldown + 0.1)
            await coordinator.handleCommandTranscript(CommandTranscript(text: "start", isFinal: true))
            #expect(recognized == [.start, .start], "after the cooldown the command must work again")
        }
    }

    // MARK: - Window closed during ANY TTS (#110 root cause #3)

    /// WHY: `handleAnswerResponse` transitions to `.showingResult`, arms the
    /// command window and only THEN plays feedback TTS — so the recognizer was
    /// transcribing the app's own voice. The build-33 field transcripts
    /// "you said proud answer proud" and "he is proud of you" are exactly that.
    @Test("the window is CLOSED while feedback TTS plays and a transcript is dropped")
    func windowClosedDuringFeedbackTTS() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeCommandVM()
            vm.quizState = makeResultState()
            #expect(vm.voiceCommandCoordinator.currentCommandScreen == .result)

            var recognized: [VoiceCommand] = []
            vm.voiceCommandCoordinator.onCommandRecognized = { recognized.append($0) }

            vm.isPlayingFeedbackTTS = true
            #expect(vm.voiceCommandCoordinator.currentCommandScreen == nil, "feedback TTS must close the window too")

            await vm.voiceCommandCoordinator.handleCommandTranscript(CommandTranscript(text: "next", isFinal: true))
            #expect(recognized.isEmpty, "a transcript arriving during feedback must be dropped, not routed")

            vm.isPlayingFeedbackTTS = false
            #expect(vm.voiceCommandCoordinator.currentCommandScreen == .result, "and reopen when the app stops talking")
        }
    }

    /// WHY: the flag is only worth anything if the playback path actually sets
    /// it AND tears the input tap down — a closed "window" over a live mic still
    /// feeds the recognizer the app's own feedback audio.
    @Test("playing result feedback tears the listener down and re-arms it after")
    func feedbackPlaybackTearsListenerDown() async {
        let (vm, silence, _) = makeCommandVM()
        vm.quizState = makeResultState()
        await vm.audioDeviceState.startSilenceDetectionListening()
        #expect(silence.isListening)
        let stopsBefore = silence.stopListeningCallCount

        _ = await vm.audioDeviceState.playFeedbackAudioBase64("ZmFrZQ==")

        #expect(silence.stopListeningCallCount > stopsBefore, "feedback must stop the mic — the app must not hear itself")
        #expect(vm.isPlayingFeedbackTTS == false, "the flag must not leak past playback")
        #expect(silence.isListening, "the window re-arms once feedback ends")
    }

    // MARK: - Defensive degrade to buttons (E-fallback)

    @Test("a failed recognizer setup leaves button-only mode: no crash, buttons work")
    func failedSetupDegradesToButtons() async {
        let (vm, silence, audio) = makeCommandVM()
        let mock = silence
        mock.shouldFailSetup = true

        vm.quizState = .askingQuestion
        await vm.voiceCommandCoordinator.syncCommandListenerWindow()
        // Setup failed → listener stays DOWN, no command layer, no crash.
        #expect(mock.isListening == false)
        #expect(mock.startListeningCallCount >= 1, "setup was attempted")

        // The manual mic button still works (batch path — no STT service).
        await vm.recordingCoordinator.startRecording()
        #expect(vm.quizState == .recording)
        #expect(audio.isRecording == true)
    }
}
